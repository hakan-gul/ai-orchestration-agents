#!/usr/bin/env python3
"""Condense a verification log into what the lead / a retrying agent needs.

Usage: testdigest.py pass|fail LOGFILE [MAX_LINES]

pass -> one line: detected test counts, skipped/no-tests flags, warning count (+ first few warnings)
fail -> every error line (with short continuation context), deduplicated, grouped counts per file;
        capped only as a safety net (default 150 lines / 15 KB) so a 2000-error tsc run cannot flood context.
Output lines are meant to be printed under the TESTS(wrapper) line as-is.
"""
import re, sys
from collections import Counter, OrderedDict

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\r")
ERR = re.compile(
    r"error|ERROR|Error\b|FAIL|[Ff]ailed|failure|✗|✘|×|❌|⨯|Exception|Fatal|Traceback|Assertion|"
    r"Expected|Received|expected .* (to|but)|\bassert|TS\d{4}|Parse error|Undefined (index|variable|offset|array key|method|property)|"
    r"Cannot find|Could not|Uncaught|panic:|SyntaxError|TypeError|ReferenceError|RangeError|Segmentation|"
    r"Unhandled|not ok\b|Diff:|\bBAD\b|^\s*(NG|NOK)\b|exit(ed)? (with )?code [1-9]|Exit status [1-9]|timed? ?out"
)
# boilerplate that matches ERR but says nothing about the cause
NOISE = re.compile(
    r"npm (ERR!|error) (A complete log|code |errno |This is probably not|Failed at the|Lifecycle script .* failed|"
    r"command (failed|sh -c)|path |workspace |location |signal |Make sure|Tell the author)|"
    r"^\s*at .*(node:internal|node_modules)/|^\s*(npm (ERR!|error))\s*$|ELIFECYCLE|"
    r"^\s*\d+ (passed|skipped)|Done in \d|0 errors?\b|no errors"
)
FILEREF = re.compile(r"([\w@./\\-]+\.(?:tsx?|jsx?|mjs|cjs|vue|svelte|php|py|css|scss|go|rs|java|kt|swift|blade\.php))(?:[(:](\d+))")
COUNTS = [
    re.compile(r"Tests?:?\s+(.*?\d+ (?:passed|failed|skipped|todo|pending|risky|incomplete).*)", re.I),
    re.compile(r"^\s*OK \((\d+ tests?, \d+ assertions?)\)"),
    re.compile(r"^\s*(\d+ (?:passed|failed|skipped|flaky)(?:,? \d+ (?:passed|failed|skipped))*(?: \([\d.]+m?s\))?)\s*$"),
    re.compile(r"=+ (.*\d+ (?:passed|failed|errors?|skipped).*?) in [\d.]+s"),
    re.compile(r"(\d+ problems? \(\d+ errors?, \d+ warnings?\))"),
    re.compile(r"(Found \d+ errors?(?: in \d+ files?)?)"),
]
NOTESTS = re.compile(r"No tests? (found|executed)|no test files|0 tests?,|Tests:\s+0 |ran 0 tests", re.I)
WARN = re.compile(r"\bwarn(ing)?s?\b|⚠|Deprecated", re.I)
WARN_ZERO = re.compile(r"\b0 warnings?\b", re.I)


def read(path):
    try:
        raw = open(path, errors="replace").read()
    except OSError:
        return []
    return [ANSI.sub("", l).rstrip() for l in raw.splitlines()]


def counts(lines):
    found = []
    for l in lines:
        for rx in COUNTS:
            m = rx.search(l)
            if m:
                s = " ".join(m.group(1).split())[:120]
                if s not in found:
                    found.append(s)
                break
    return found[-3:]


def clip(l, n=300):
    return l if len(l) <= n else l[:n] + "…"


def passed(lines):
    c = counts(lines)
    warns = [l for l in lines if WARN.search(l) and not WARN_ZERO.search(l)]
    parts = ["; ".join(c) if c else "no test counts in output"]
    if any(NOTESTS.search(l) for l in lines):
        parts.append("NO TESTS RAN — exit 0 proves nothing")
    if warns:
        parts.append(f"{len(warns)} warning line(s)")
    if not any(l.strip() for l in lines):
        parts = ["clean (no output)"]
    print(" | ".join(parts) + f" ({len(lines)} log lines)")
    for w in list(OrderedDict.fromkeys(w.strip() for w in warns))[:3]:
        print("  ! " + clip(w, 200))


FRAME_NOISE = re.compile(r"^\s+at .*(node:internal|node_modules|\[eval\]-wrapper)|^Node\.js v\d|^\s*npm (ERR!|error) (A complete log|errno|code )")
SHORT_LOG = 60


def failed(lines, max_lines):
    # short log: the whole thing (minus framework stack frames / blanks) is the most complete diagnosis
    body = [l for l in lines if l.strip() and not FRAME_NOISE.search(l)]
    if len(body) <= SHORT_LOG:
        c = counts(lines)
        if c:
            print("  summary: " + "; ".join(c))
        print(f"  full log ({len(body)} lines, noise frames dropped):")
        for l in body:
            print("  | " + clip(l))
        return
    picked, seen = [], Counter()
    i = 0
    while i < len(lines):
        l = lines[i]
        if l.strip() and ERR.search(l) and not NOISE.search(l):
            block = [l]
            # short continuation context: indented / code-frame / "Expected..Received" lines that follow
            j = i + 1
            while j < len(lines) and len(block) < 4 and lines[j].strip() and (
                lines[j][:1] in " \t>|" or re.match(r"\s*\d+\s*[|│]", lines[j])
            ) and not re.match(r"\s+at ", lines[j]):
                block.append(lines[j])
                j += 1
            key = block[0].strip()
            seen[key] += 1
            if seen[key] == 1:
                picked.append(block)
            i = j
        else:
            i += 1

    c = counts(lines)
    if c:
        print("  summary: " + "; ".join(c))
    if not picked:
        print(f"  (no error pattern matched; last 40 of {len(lines)} lines)")
        for l in lines[-40:]:
            print("  | " + clip(l))
        return

    out, size, shown = [], 0, 0
    for b in picked:
        rows = ["  | " + clip(b[0]) + (f"  (x{seen[b[0].strip()]})" if seen[b[0].strip()] > 1 else "")]
        rows += ["  |   " + clip(x.strip(), 200) for x in b[1:]]
        if len(out) + len(rows) > max_lines or size > 15000:
            break
        out += rows
        size += sum(len(r) for r in rows)
        shown += 1
    print(f"  error blocks: {len(picked)} unique ({sum(seen.values())} total) in {len(lines)} log lines")
    print("\n".join(out))
    if shown < len(picked):
        files = Counter()
        for b in picked[shown:]:
            for m in FILEREF.finditer(b[0]):
                files[m.group(1)] += 1
        top = ", ".join(f"{f}({n})" for f, n in files.most_common(10))
        print(f"  … +{len(picked) - shown} more error blocks omitted" + (f"; by file: {top}" if top else ""))


if __name__ == "__main__":
    mode, path = sys.argv[1], sys.argv[2]
    mx = int(sys.argv[3]) if len(sys.argv) > 3 else 150
    lines = read(path)
    passed(lines) if mode == "pass" else failed(lines, mx)
