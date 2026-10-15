#!/usr/bin/env bash
set -uo pipefail

D="$(cd "$(dirname "$0")/.." && pwd)"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export AI_AGENTS_STATE="$TMPDIR/state"
export AI_AGENTS_STUB_BIN="$TMPDIR/bin"
export CURSOR_MODEL=stub-composer
export GEMINI_CLI=agy

mkdir -p "$AI_AGENTS_STATE" "$AI_AGENTS_STUB_BIN"
cp "$D/tests/stubs/agy" "$AI_AGENTS_STUB_BIN/agy"
cp "$D/tests/stubs/agent" "$AI_AGENTS_STUB_BIN/agent"
chmod +x "$AI_AGENTS_STUB_BIN/agy" "$AI_AGENTS_STUB_BIN/agent"
chmod +x "$D/tests/stubs/agy" "$D/tests/stubs/agent" 2>/dev/null || true

export PATH="$AI_AGENTS_STUB_BIN:$PATH"

PASSED=0
FAILED=0

run_test() {
  local name="$1"
  local fn="$2"
  local reason=""
  if reason="$($fn 2>&1)"; then
    echo "ok $name"
    PASSED=$((PASSED + 1))
  else
    local single_line_reason
    single_line_reason="$(echo "$reason" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    echo "FAIL $name: ${single_line_reason:-unknown error}"
    FAILED=$((FAILED + 1))
  fi
}

# 1 gemini success -> delegate exit 0, OUTCOME: success, attempt header shows gemini
test_1() {
  local ws="$TMPDIR/ws1"
  mkdir -p "$ws"
  rm -f "$AI_AGENTS_STATE/gemini-cooldown"
  local out rc
  out="$(STUB_GEMINI=success STUB_CURSOR=fail "$D/delegate.sh" simple -C "$ws" "task 1" 2>&1)"
  rc=$?
  [ $rc -eq 0 ] || { echo "delegate exited $rc, expected 0 (output: $out)"; return 1; }
  echo "$out" | grep -q "OUTCOME: success" || { echo "OUTCOME: success missing in output: $out"; return 1; }
  echo "$out" | grep -qE "=== \[[0-9]+: simple\] gemini ===" || { echo "gemini attempt header missing in output: $out"; return 1; }
  return 0
}

# 2 gemini quota -> second attempt is cursor, exit 0, state/gemini-cooldown exists
test_2() {
  local ws="$TMPDIR/ws2"
  mkdir -p "$ws"
  rm -f "$AI_AGENTS_STATE/gemini-cooldown"
  local out rc
  out="$(STUB_GEMINI=quota STUB_CURSOR=success "$D/delegate.sh" simple -C "$ws" "task 2" 2>&1)"
  rc=$?
  [ $rc -eq 0 ] || { echo "delegate exited $rc, expected 0 (output: $out)"; return 1; }
  echo "$out" | grep -qE "=== \[[0-9]+: simple via cursor\] cursor ===" || { echo "second attempt cursor header missing: $out"; return 1; }
  [ -f "$AI_AGENTS_STATE/gemini-cooldown" ] || { echo "state/gemini-cooldown missing"; return 1; }
  return 0
}

# 3 active cooldown -> first attempt is cursor (no gemini header)
test_3() {
  local ws="$TMPDIR/ws3"
  mkdir -p "$ws"
  mkdir -p "$AI_AGENTS_STATE"
  echo "$(( $(date +%s) + 3600 )) daily quota exhausted" > "$AI_AGENTS_STATE/gemini-cooldown"
  local out rc
  out="$(STUB_GEMINI=fail STUB_CURSOR=success "$D/delegate.sh" simple -C "$ws" "task 3" 2>&1)"
  rc=$?
  [ $rc -eq 0 ] || { echo "delegate exited $rc, expected 0 (output: $out)"; return 1; }
  echo "$out" | grep -qE "=== \[1: simple via cursor\] cursor ===" || { echo "first attempt cursor header missing: $out"; return 1; }
  if echo "$out" | grep -qE "=== \[[0-9]+: .*\] gemini ==="; then
    echo "unexpected gemini attempt header found in output: $out"
    return 1
  fi
  return 0
}

# 4 test_failure: STUB_GEMINI=badjs, STUB_CURSOR=fail, --test "node -e 'require(\"./code.js\")'" -> OUTCOME: test_failure appears, exit 3, and the cursor run's prompt.txt (newest dir under state/runs/*cursor*) contains "SyntaxError"
test_4() {
  local ws="$TMPDIR/ws4"
  mkdir -p "$ws"
  rm -f "$AI_AGENTS_STATE/gemini-cooldown"
  rm -rf "$AI_AGENTS_STATE/runs"
  mkdir -p "$AI_AGENTS_STATE/runs"
  local test_cmd='node -e '\''require("./code.js")'\'
  local out rc
  out="$(STUB_GEMINI=badjs STUB_CURSOR=fail "$D/delegate.sh" simple -C "$ws" --test "$test_cmd" "task 4" 2>&1)"
  rc=$?
  [ $rc -eq 3 ] || { echo "expected exit 3, got $rc (output: $out)"; return 1; }
  echo "$out" | grep -q "OUTCOME: test_failure" || { echo "OUTCOME: test_failure missing in output: $out"; return 1; }
  local cursor_dir
  cursor_dir="$(ls -td "$AI_AGENTS_STATE"/runs/*cursor* 2>/dev/null | head -1)"
  [ -n "$cursor_dir" ] || { echo "no cursor run directory found under state/runs"; return 1; }
  [ -f "$cursor_dir/prompt.txt" ] || { echo "prompt.txt missing in $cursor_dir"; return 1; }
  grep -q "SyntaxError" "$cursor_dir/prompt.txt" || { echo "SyntaxError not found in $cursor_dir/prompt.txt"; return 1; }
  return 0
}

# 5 scope: STUB_GEMINI=outscope STUB_CURSOR=fail --scope "src/" -> OUTCOME: scope_violation and "outside.txt" listed under OUT-OF-SCOPE
test_5() {
  local ws="$TMPDIR/ws5"
  mkdir -p "$ws"
  rm -f "$AI_AGENTS_STATE/gemini-cooldown"
  local out rc
  out="$(STUB_GEMINI=outscope STUB_CURSOR=fail "$D/delegate.sh" simple -C "$ws" --scope "src/" "task 5" 2>&1)"
  rc=$?
  echo "$out" | grep -q "OUTCOME: scope_violation" || { echo "OUTCOME: scope_violation missing: $out"; return 1; }
  echo "$out" | grep -A 2 "OUT-OF-SCOPE" | grep -q "outside.txt" || { echo "outside.txt not listed under OUT-OF-SCOPE: $out"; return 1; }
  return 0
}

# 6 image level with cooldown active -> exit 3, no run dirs created
test_6() {
  local ws="$TMPDIR/ws6"
  mkdir -p "$ws"
  mkdir -p "$AI_AGENTS_STATE"
  echo "$(( $(date +%s) + 3600 )) daily quota exhausted" > "$AI_AGENTS_STATE/gemini-cooldown"
  rm -rf "$AI_AGENTS_STATE/runs"
  mkdir -p "$AI_AGENTS_STATE/runs"
  local out rc
  out="$(STUB_GEMINI=fail STUB_CURSOR=fail "$D/delegate.sh" image -C "$ws" "task 6" 2>&1)"
  rc=$?
  [ $rc -eq 3 ] || { echo "expected exit 3, got $rc (output: $out)"; return 1; }
  local runs_count
  runs_count="$(find "$AI_AGENTS_STATE/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
  [ "$runs_count" -eq 0 ] || { echo "$runs_count run dirs created under state/runs"; return 1; }
  return 0
}

# 7 image level success -> exit 0, IMAGES: line lists icon.png
test_7() {
  local ws="$TMPDIR/ws7"
  mkdir -p "$ws"
  rm -f "$AI_AGENTS_STATE/gemini-cooldown"
  local out rc
  out="$(STUB_GEMINI=image STUB_CURSOR=fail "$D/delegate.sh" image -C "$ws" "task 7" 2>&1)"
  rc=$?
  [ $rc -eq 0 ] || { echo "delegate exited $rc, expected 0 (output: $out)"; return 1; }
  echo "$out" | grep -q "^IMAGES:" || { echo "IMAGES: line missing in output: $out"; return 1; }
  echo "$out" | grep -A 2 "^IMAGES:" | grep -q "icon.png" || { echo "icon.png missing under IMAGES: in output: $out"; return 1; }
  return 0
}

# 8 --isolate in a git repo: main tree unchanged after delegate; wt.sh apply -> "OUTCOME: applied" and file present in main; second apply -> apply_conflict; wt.sh discard removes it
test_8() {
  local ws="$TMPDIR/ws8"
  mkdir -p "$ws"
  git -C "$ws" init -q
  git -C "$ws" config user.name "tester"
  git -C "$ws" config user.email "tester@local"
  echo "init" > "$ws/base.txt"
  git -C "$ws" add base.txt
  git -C "$ws" commit -q -m "init"

  rm -f "$AI_AGENTS_STATE/gemini-cooldown"
  local out rc
  out="$(STUB_GEMINI=success STUB_CURSOR=fail "$D/delegate.sh" simple -C "$ws" --isolate testiso "test isolate" 2>&1)"
  rc=$?
  [ $rc -eq 0 ] || { echo "delegate failed ($rc): $out"; return 1; }

  # main tree unchanged after delegate
  if [ -e "$ws/code.js" ] || [ -e "$ws/src/in.txt" ]; then
    echo "main tree was modified during isolate run"; return 1
  fi
  if [ -n "$(git -C "$ws" status --porcelain)" ]; then
    echo "main git status not clean"; return 1
  fi

  # wt.sh apply -> "OUTCOME: applied" and file present in main
  local apply_out apply_rc
  apply_out="$("$D/wt.sh" apply testiso 2>&1)"
  apply_rc=$?
  [ $apply_rc -eq 0 ] || { echo "wt.sh apply failed ($apply_rc): $apply_out"; return 1; }
  echo "$apply_out" | grep -q "OUTCOME: applied" || { echo "apply output missing 'OUTCOME: applied': $apply_out"; return 1; }
  [ -f "$ws/code.js" ] && [ -f "$ws/src/in.txt" ] || { echo "files not present in main after apply"; return 1; }

  # second apply -> apply_conflict
  local apply2_out apply2_rc
  apply2_out="$("$D/wt.sh" apply testiso 2>&1)"
  apply2_rc=$?
  [ $apply2_rc -ne 0 ] || { echo "second apply unexpectedly succeeded: $apply2_out"; return 1; }
  echo "$apply2_out" | grep -q "OUTCOME: apply_conflict" || { echo "second apply missing 'OUTCOME: apply_conflict': $apply2_out"; return 1; }

  # wt.sh discard removes it
  local discard_out discard_rc
  discard_out="$("$D/wt.sh" discard testiso 2>&1)"
  discard_rc=$?
  [ $discard_rc -eq 0 ] || { echo "wt.sh discard failed ($discard_rc): $discard_out"; return 1; }
  if "$D/wt.sh" list 2>/dev/null | grep -q "^testiso\b"; then
    echo "testiso still listed after discard"; return 1
  fi
  if [ -d "$AI_AGENTS_STATE/worktrees/testiso" ]; then
    echo "worktree dir still exists after discard"; return 1
  fi
  return 0
}

# 9 wt.sh apply conflict: main file edited after ensure on the same line -> apply_conflict
test_9() {
  local ws="$TMPDIR/ws9"
  mkdir -p "$ws"
  git -C "$ws" init -q
  git -C "$ws" config user.name "tester"
  git -C "$ws" config user.email "tester@local"
  printf "line 1\nline 2\nline 3\n" > "$ws/file.txt"
  git -C "$ws" add file.txt
  git -C "$ws" commit -q -m "init"

  local wt_path
  wt_path="$("$D/wt.sh" ensure "$ws" wtconf 2>&1)"
  [ -d "$wt_path" ] || { echo "wt.sh ensure failed: $wt_path"; return 1; }

  printf "line 1\nline 2 in worktree\nline 3\n" > "$wt_path/file.txt"
  printf "line 1\nline 2 in main\nline 3\n" > "$ws/file.txt"

  local apply_out apply_rc
  apply_out="$("$D/wt.sh" apply wtconf 2>&1)"
  apply_rc=$?
  [ $apply_rc -ne 0 ] || { echo "apply unexpectedly succeeded: $apply_out"; return 1; }
  echo "$apply_out" | grep -q "OUTCOME: apply_conflict" || { echo "apply missing 'OUTCOME: apply_conflict': $apply_out"; return 1; }

  "$D/wt.sh" discard wtconf >/dev/null 2>&1 || true
  return 0
}

# 10 testdigest.py: fail mode on a 300-line synthetic tsc log prints "more error blocks omitted"; pass mode on "Tests:  2 skipped, 40 passed" prints "40 passed"; pass mode on empty log prints "clean"
test_10() {
  local log_fail="$TMPDIR/tsc_300.log"
  local i
  for i in $(seq 1 300); do
    echo "src/file$i.ts(1,1): error TS2304: Cannot find name 'foo$i'."
  done > "$log_fail"

  local out_fail
  out_fail="$(python3 "$D/testdigest.py" fail "$log_fail" 2>&1)"
  echo "$out_fail" | grep -q "more error blocks omitted" || { echo "fail mode missing 'more error blocks omitted': $out_fail"; return 1; }

  local log_pass="$TMPDIR/pass.log"
  echo "Tests:  2 skipped, 40 passed" > "$log_pass"
  local out_pass
  out_pass="$(python3 "$D/testdigest.py" pass "$log_pass" 2>&1)"
  echo "$out_pass" | grep -q "40 passed" || { echo "pass mode missing '40 passed': $out_pass"; return 1; }

  local log_empty="$TMPDIR/empty.log"
  : > "$log_empty"
  local out_empty
  out_empty="$(python3 "$D/testdigest.py" pass "$log_empty" 2>&1)"
  echo "$out_empty" | grep -q "clean" || { echo "empty log missing 'clean': $out_empty"; return 1; }

  return 0
}

# 11 lib.sh scope_violations: "src/, tests/*.test.ts" flags README.md and package-lock.json but not src/a/b.ts or tests/x.test.ts
test_11() {
  local input out
  input=$(printf "README.md\npackage-lock.json\nsrc/a/b.ts\ntests/x.test.ts\n")
  out=$(printf '%s\n' "$input" | ( source "$D/lib.sh" && scope_violations "src/, tests/*.test.ts" ))
  echo "$out" | grep -q "^README\.md$" || { echo "README.md not flagged: $out"; return 1; }
  echo "$out" | grep -q "^package-lock\.json$" || { echo "package-lock.json not flagged: $out"; return 1; }
  if echo "$out" | grep -q "src/a/b\.ts"; then
    echo "src/a/b.ts was unexpectedly flagged: $out"; return 1
  fi
  if echo "$out" | grep -q "tests/x\.test\.ts"; then
    echo "tests/x.test.ts was unexpectedly flagged: $out"; return 1
  fi
  return 0
}

run_test "1 gemini success" test_1
run_test "2 gemini quota" test_2
run_test "3 active cooldown" test_3
run_test "4 test_failure" test_4
run_test "5 scope" test_5
run_test "6 image level with cooldown active" test_6
run_test "7 image level success" test_7
run_test "8 --isolate in a git repo" test_8
run_test "9 wt.sh apply conflict" test_9
run_test "10 testdigest.py" test_10
run_test "11 lib.sh scope_violations" test_11

echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
