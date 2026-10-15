#!/usr/bin/env bash
# Isolated git worktrees for parallel / reviewable sub-agent runs (git projects only).
#
#   wt.sh ensure MAIN NAME     create (or reuse) worktree NAME for repo MAIN; prints its path
#   wt.sh diff NAME [--stat]   what the agent(s) changed in NAME (vs. the snapshot taken at creation)
#   wt.sh apply NAME           apply those changes onto MAIN's working tree  -> OUTCOME: applied | no_changes | apply_conflict
#   wt.sh discard NAME         remove the worktree (after apply or to abandon)
#   wt.sh list
#
# Unlike a plain `git worktree add HEAD`, the worktree starts from MAIN's *current* state: uncommitted
# changes and untracked (non-ignored) files are copied in, .env* files copied, node_modules/vendor symlinked,
# so the agent sees the real code and the wrapper's --test can run there. That state is committed inside
# the worktree as the base; apply = `git apply --check` + `git apply` of (base -> now) onto MAIN.
source "$(dirname "$0")/lib.sh"
WT_DIR="$STATE_DIR/worktrees"
CMD="${1:-}"; shift || true

meta() { echo "$WT_DIR/$1.meta"; }
load() {  # $1=NAME -> main, path, base, applied
  [ -f "$(meta "$1")" ] || die "no such worktree: $1 (wt.sh list)"
  . "$(meta "$1")"
}
# heavy / generated dirs: symlinked or never part of the patch
EXCL=(':(exclude,glob)**/node_modules' ':(exclude,glob)**/node_modules/**' ':(exclude,glob)**/vendor' ':(exclude,glob)**/vendor/**')
stage() { git -C "$path" add -A -- . "${EXCL[@]}" >/dev/null 2>&1; }

case "$CMD" in
ensure)
  MAIN="$(cd "${1:?MAIN}" && pwd)"; NAME="${2:?NAME}"
  case "$NAME" in *[!A-Za-z0-9._-]*) die "bad worktree name: $NAME";; esac
  if [ -f "$(meta "$NAME")" ]; then
    load "$NAME"; [ "$main" = "$MAIN" ] || die "worktree $NAME belongs to $main"
    [ -d "$path" ] || die "worktree $NAME vanished: $path"
    echo "$path"; exit 0
  fi
  TOP="$(git -C "$MAIN" rev-parse --show-toplevel 2>/dev/null)" || die "--isolate needs a git repository: $MAIN"
  [ "$TOP" = "$MAIN" ] || die "--isolate: use the repo root as -C ($TOP), not a subdirectory"
  git -C "$MAIN" rev-parse -q --verify HEAD >/dev/null || die "--isolate: repo has no commits yet"
  mkdir -p "$WT_DIR"; path="$WT_DIR/$NAME"
  git -C "$MAIN" worktree add -q --detach "$path" HEAD >/dev/null 2>&1 || die "git worktree add failed"
  # current uncommitted state
  git -C "$MAIN" diff --binary HEAD > "$path.overlay.patch"
  [ -s "$path.overlay.patch" ] && { git -C "$path" apply --binary "$path.overlay.patch" || die "could not copy uncommitted changes"; }
  rm -f "$path.overlay.patch"
  git -C "$MAIN" ls-files -z --others --exclude-standard | rsync -a --from0 --files-from=- "$MAIN/" "$path/"
  for f in "$MAIN"/.env "$MAIN"/.env.*; do [ -f "$f" ] && [ ! -e "$path/${f##*/}" ] && cp -p "$f" "$path/"; done
  # dependency dirs (repo root and one level down, e.g. mobile/node_modules)
  while IFS= read -r d; do
    rel="${d#"$MAIN"/}"; [ -e "$path/$rel" ] || { mkdir -p "$(dirname "$path/$rel")"; ln -s "$d" "$path/$rel"; }
  done < <(find "$MAIN" -maxdepth 3 \( -name node_modules -o -name vendor \) -type d -prune -not -path '*/node_modules/*' 2>/dev/null)
  stage
  git -C "$path" -c user.name=agents -c user.email=agents@local commit -q --no-verify --allow-empty -m "wt base $NAME" >/dev/null
  base="$(git -C "$path" rev-parse HEAD)"
  printf 'main=%q\npath=%q\nbase=%q\napplied=0\ncreated=%q\n' "$MAIN" "$path" "$base" "$(date -Is)" > "$(meta "$NAME")"
  echo "$path"
  ;;
diff)
  load "${1:?NAME}"; stage
  if [ "$2" = --stat ]; then git -C "$path" diff --cached --stat "$base"
  else git -C "$path" diff --cached -U2 "$base" -- "${@:2}"; fi
  ;;
apply)
  NAME="${1:?NAME}"; load "$NAME"; stage
  P="$WT_DIR/$NAME.patch"; git -C "$path" diff --cached --binary "$base" > "$P"
  if [ ! -s "$P" ]; then echo "OUTCOME: no_changes"; exit 0; fi
  if [ "$applied" = 1 ]; then echo "OUTCOME: apply_conflict"; echo "REASON: already applied (wt.sh discard $NAME)"; exit 1; fi
  if ! ERR="$(git -C "$main" apply --check --binary "$P" 2>&1)"; then
    echo "OUTCOME: apply_conflict"
    echo "REASON: main tree changed/overlaps since the worktree was created:"; echo "$ERR" | head -15 | sed 's/^/  | /'
    echo "NEXT: discard and re-delegate against the current tree, or merge by hand (patch: $P)"; exit 1
  fi
  git -C "$main" apply --binary "$P" || { echo "OUTCOME: apply_error"; exit 1; }
  sed -i 's/^applied=.*/applied=1/' "$(meta "$NAME")"
  OWNER="$(stat -c %u:%g "$main")"
  [ "$OWNER" != 0:0 ] && git -C "$path" diff --cached --name-only --diff-filter=d "$base" | while IFS= read -r f; do
    [ -e "$main/$f" ] && chown "$OWNER" "$main/$f"; done
  echo "OUTCOME: applied"; git -C "$path" diff --cached --stat "$base" | tail -1
  echo "NEXT: review/test in $main, then: wt.sh discard $NAME"
  ;;
discard)
  NAME="${1:?NAME}"; load "$NAME"
  git -C "$main" worktree remove --force "$path" 2>/dev/null || rm -rf "$path"
  git -C "$main" worktree prune 2>/dev/null
  rm -rf "$SHADOW_DIR/$(printf %s "$path" | md5sum | cut -c1-12).git" "$(meta "$NAME")" "$WT_DIR/$NAME.patch"
  echo "discarded $NAME"
  ;;
list)
  for m in "$WT_DIR"/*.meta; do
    [ -f "$m" ] || continue; ( . "$m"; n="$(basename "$m" .meta)"
      echo "$n  applied=$applied  created=$created  main=$main" )
  done
  ;;
*) echo "usage: wt.sh ensure MAIN NAME | diff NAME [--stat|FILE..] | apply NAME | discard NAME | list" >&2; exit 2;;
esac
