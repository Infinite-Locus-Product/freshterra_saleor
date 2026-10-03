#!/usr/bin/env bash
# Test gate (Delivery Rule 6).
#   pre-push  : FULL suite must pass >= THRESHOLD % (default 98). Blocks on 0 tests, missing deps,
#               runner crash, load/collection/build errors.  pass % = passed / (passed + failed);
#               skipped tests are reported but not counted.
#   pre-commit: tests related to staged files (jest / jest-workspaces / vitest); other runners skip.
# Config: .test-gate.conf (committed) + optional .test-gate.local.conf (gitignored: FRAPPE_BENCH,
# FRAPPE_SITE, PYTHON, MAX_WORKERS only). Logs: <git-dir>/test-gate/. Bypass only when Sachin says so.
set -uo pipefail

MODE="${1:-pre-push}"
ROOT="$(git rev-parse --show-toplevel)" || exit 1
cd "$ROOT" || exit 1
CONF="$ROOT/.test-gate.conf"; [ -n "${GATE_SELFTEST_CONF:-}" ] && CONF="$GATE_SELFTEST_CONF"
die() { echo "test-gate: BLOCKED - $*" >&2; exit 1; }
[ -f "$CONF" ] || die "missing .test-gate.conf"

RUNNER=""; THRESHOLD=98; MAX_WORKERS=2; JEST_CONFIGS=""; JEST_ARGS=""; WORKSPACE_GLOB=""
PYTHON="python3"; NODE_TEST_GLOB=""; PYTEST_ARGS=""; GO_PKGS="./..."; CUSTOM_CMD=""
FRAPPE_BENCH=""; FRAPPE_SITE=""; FRAPPE_APP=""; PRE_CMD=""; TIMEOUT_MIN=60
unset PYTEST_ADDOPTS
# shellcheck disable=SC1090
. "$CONF" || die "error in $CONF"
# local conf: plain KEY=VALUE lines, allowlisted keys only (it may not weaken the gate)
if [ -f "$ROOT/.test-gate.local.conf" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"; v="${v%\"}"; v="${v#\"}"
    case "$k" in
      FRAPPE_BENCH) FRAPPE_BENCH="$v" ;; FRAPPE_SITE) FRAPPE_SITE="$v" ;; PYTHON) PYTHON="$v" ;;
      MAX_WORKERS) case "$v" in ''|*[!0-9]*) die "MAX_WORKERS must be a number" ;; esac; MAX_WORKERS="$v" ;;
      *) die ".test-gate.local.conf: key '$k' not allowed (only FRAPPE_BENCH, FRAPPE_SITE, PYTHON, MAX_WORKERS)" ;;
    esac
  done < "$ROOT/.test-gate.local.conf"
fi
[ -n "$RUNNER" ] || die "RUNNER not set in .test-gate.conf"
case "$THRESHOLD" in ''|*[!0-9]*) die "THRESHOLD must be an integer 1-100" ;; esac
THRESHOLD=$((10#$THRESHOLD))
[ "$THRESHOLD" -ge 1 ] && [ "$THRESHOLD" -le 100 ] || die "THRESHOLD must be 1-100"

LOGDIR="$(git rev-parse --absolute-git-dir)/test-gate"; mkdir -p "$LOGDIR"; [ "$MODE" = pre-push ] && rm -f "$LOGDIR"/*
N=0; PASSED=0; FAILED=0; SKIPPED=0; ERRORS=""
newlog() { N=$((N + 1)); LOG="$LOGDIR/$1-$N.log"; OUT="$LOGDIR/$1-$N.out"; rm -f "$OUT"; }
err() { ERRORS="${ERRORS}  - $*"$'\n'; }
# tmo <cmd...>: run with a TIMEOUT_MIN limit (macOS has no `timeout`); exit 142 on timeout
tmo() { perl -e '$t=shift; $p=fork; if(!$p){exec @ARGV; exit 127} $SIG{ALRM}=sub{kill "TERM",-$p,$p; sleep 5; kill "KILL",$p; exit 142}; alarm $t; waitpid($p,0); exit($? >> 8)' "$((TIMEOUT_MIN * 60))" "$@"; }

# parse.py <kind> <file> <rc> -> prints "passed failed skipped" + failing names on stderr; exit 3 = unusable/crash
PARSE="$LOGDIR/parse.py"
cat > "$PARSE" <<'PY'
import json, sys, re, xml.etree.ElementTree as ET
kind, path, rc = sys.argv[1], sys.argv[2], int(sys.argv[3])
p = f = s = 0; names = []; crash = None
try:
    if kind == "jest":            # jest + vitest json
        d = json.load(open(path))
        p, f = d.get("numPassedTests", 0), d.get("numFailedTests", 0)
        s = d.get("numPendingTests", 0) + d.get("numTodoTests", 0)
        if d.get("numRuntimeErrorTestSuites", 0): crash = "%d test file(s) failed to load" % d["numRuntimeErrorTestSuites"]
        for r in d.get("testResults", []):
            bad = [a for a in r.get("assertionResults", []) if a.get("status") == "failed"]
            names += ["%s > %s" % (r.get("name", "?").split("/")[-1], a.get("fullName") or a.get("title")) for a in bad]
            if r.get("status") == "failed" and not bad:
                crash = "suite failed without failed tests (load error): " + r.get("name", "?")
        if rc != 0 and f == 0 and not crash:
            crash = ("no test files found (0 tests)" if p == 0 else "runner exited %d with no failed tests" % rc)
    elif kind == "junit":
        root = ET.parse(path).getroot()
        for tc in root.iter("testcase"):
            tags = {c.tag for c in tc}; nm = "%s.%s" % (tc.get("classname", ""), tc.get("name", ""))
            if re.search(r"setUpClass|setUpModule|tearDownClass|_FailedTest", nm) and tags & {"failure", "error"}:
                crash = "load/collection error: " + nm
            if "skipped" in tags: s += 1
            elif tags & {"failure", "error"}: f += 1; names.append(nm)
            else: p += 1
        for e in root.iter("error"):
            if "collection" in (e.get("message") or "").lower(): crash = "collection failure"
    elif kind == "go":
        pkg_fail, pkg_testfail = set(), set()
        for line in open(path):
            try: e = json.loads(line)
            except Exception: continue
            a, pkg = e.get("Action"), e.get("Package") or e.get("ImportPath") or "?"
            if a == "build-fail": crash = "build failed: " + pkg; continue
            out = e.get("Output", "") if a == "output" else ""
            if out.startswith("panic: ") or "test timed out" in out or "[build failed]" in out or "[setup failed]" in out:
                crash = "panic/timeout/build failure in " + pkg
            if not e.get("Test"):
                if a == "fail": pkg_fail.add(pkg)
                continue
            if "/" in e["Test"]: continue          # count top-level tests only
            if a == "pass": p += 1
            elif a == "fail": f += 1; pkg_testfail.add(pkg); names.append(pkg + " " + e["Test"])
            elif a == "skip": s += 1
        for pk in sorted(pkg_fail - pkg_testfail): crash = "package failed with no failing test (build/vet/TestMain): " + pk
        if rc != 0 and f == 0 and not crash: crash = "go test exited %d with no failed tests" % rc
    elif kind == "tap":
        txt = open(path).read()
        def last(k):
            m = re.findall(r"^# %s (\d+)$" % k, txt, re.M); return int(m[-1]) if m else 0
        p, f, s = last("pass"), last("fail") + last("cancelled"), last("skipped") + last("todo")
        names = re.findall(r"^not ok \d+ - (.*)$", txt, re.M)
        for nm in names:
            if re.search(r"\.(c|m)?(j|t)s$", nm.strip()): crash = "test file failed to load: " + nm.strip()
        if re.search(r"^\s+failureType: '(testCodeFailure|fileFailure)'[\s\S]{0,200}?exitCode:", txt, re.M) and not crash:
            crash = "a test file exited with an error before running its tests"
        if not re.search(r"^# tests \d+$", txt, re.M): crash = "no TAP summary (runner crashed?)"
        elif rc != 0 and f == 0: crash = "node --test exited %d with no failed tests" % rc
except FileNotFoundError:
    crash = "no report written (runner crashed, rc=%d)" % rc
except Exception as ex:
    crash = "unreadable report: %s" % ex
print(p, f, s)
for n in names[:30]: print("    FAIL " + n, file=sys.stderr)
if crash: print("CRASH " + crash, file=sys.stderr); sys.exit(3)
PY

collect() { # kind label rc
  local res rc_p
  res="$(python3 "$PARSE" "$1" "$OUT" "$3" 2>"$LOG.parse")"; rc_p=$?
  # shellcheck disable=SC2086
  set -- "$1" "$2" "$3" $res
  PASSED=$((PASSED + ${4:-0})); FAILED=$((FAILED + ${5:-0})); SKIPPED=$((SKIPPED + ${6:-0}))
  grep '^    FAIL' "$LOG.parse" >&2 || true
  if [ "$rc_p" -ne 0 ]; then err "$2: $(sed -n 's/^CRASH //p' "$LOG.parse") (log: $LOG)"; fi
}

run_jest_in() { # dir label extra-args
  newlog jest
  [ -d "$1/node_modules" ] || [ -d "$ROOT/node_modules" ] || { err "$2: node_modules missing, run the package install"; return; }
  # shellcheck disable=SC2086
  (cd "$1" && CI=true tmo npx --no-install jest $3 --maxWorkers="$MAX_WORKERS" --json --outputFile="$OUT" >"$LOG" 2>&1)
  collect jest "$2" $?
}

# ---------------- pre-commit ----------------
if [ "$MODE" = pre-commit ]; then
  STAGED=()
  while IFS= read -r -d '' fl; do
    case "$fl" in *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.mts|*.cts|*.vue|*.svelte) STAGED+=("$fl") ;; esac
  done < <(git diff --cached -z --name-only --diff-filter=ACMR)
  [ "${#STAGED[@]}" -eq 0 ] && exit 0
  unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE
  # shellcheck disable=SC2086
  case "$RUNNER" in
    jest)
      if [ -n "$JEST_CONFIGS" ]; then
        for c in $JEST_CONFIGS; do CI=true npx --no-install jest --config "$c" $JEST_ARGS --findRelatedTests "${STAGED[@]}" --passWithNoTests --maxWorkers="$MAX_WORKERS" || exit 1; done
      else CI=true npx --no-install jest $JEST_ARGS --findRelatedTests "${STAGED[@]}" --passWithNoTests --maxWorkers="$MAX_WORKERS" || exit 1; fi ;;
    jest-workspaces)
      for d in $WORKSPACE_GLOB; do
        [ -f "$d/package.json" ] || continue
        rel=(); for fl in "${STAGED[@]}"; do case "$fl" in "$d"/*) rel+=("$ROOT/$fl") ;; esac; done
        [ "${#rel[@]}" -eq 0 ] && continue
        (cd "$d" && CI=true npx --no-install jest $JEST_ARGS --findRelatedTests "${rel[@]}" --passWithNoTests --maxWorkers="$MAX_WORKERS") || exit 1
      done ;;
    vitest) npx --no-install vitest related --run "${STAGED[@]}" --passWithNoTests || exit 1 ;;
  esac
  exit 0
fi
[ "$MODE" = pre-push ] || { echo "usage: test-gate.sh [pre-push|pre-commit]" >&2; exit 2; }

# ---------------- pre-push ----------------
# stdin: <local ref> <local sha> <remote ref> <remote sha>. Skip pure branch deletes.
HEADSHA="$(git rev-parse HEAD)"; PUSHING=0; OTHER=""; LINES=0
if [ ! -t 0 ]; then
  while read -r lref lsha _rref _rsha; do
    [ -n "${lsha:-}" ] || continue
    LINES=$((LINES + 1))
    case "$lsha" in *[!0]*) PUSHING=1; [ "$(git rev-parse -q --verify "$lsha^{commit}")" = "$HEADSHA" ] || OTHER="$OTHER $lref" ;; esac
  done
fi
[ "$LINES" -gt 0 ] || PUSHING=1   # manual run
[ "$PUSHING" -eq 1 ] || { echo "test-gate: branch delete only, skipping."; exit 0; }
[ -z "$OTHER" ] || die "pushing refs other than the checked-out HEAD ($OTHER). Check out that branch and push from it, so the gate tests what is pushed."
if [ -n "$(git status --porcelain --untracked-files=normal -- . ':!.test-gate.local.conf')" ]; then
  die "working tree has uncommitted/untracked changes; the gate would test code you are not pushing. Commit or stash them first."
fi

if [ -n "$PRE_CMD" ]; then   # e.g. build shared workspace packages so tests compile against current code
  newlog pre; echo "test-gate: PRE_CMD: $PRE_CMD"
  eval "$PRE_CMD" >"$LOG" 2>&1 || die "PRE_CMD failed (log: $LOG)"
fi
echo "test-gate: running FULL suite ($RUNNER), threshold ${THRESHOLD}% ..."
case "$RUNNER" in
  jest)
    if [ -n "$JEST_CONFIGS" ]; then for c in $JEST_CONFIGS; do run_jest_in "$ROOT" "jest --config $c" "--config $c $JEST_ARGS"; done
    else run_jest_in "$ROOT" jest "$JEST_ARGS"; fi ;;
  jest-workspaces)   # one workspace at a time (parallel storms cause false failures)
    for d in $WORKSPACE_GLOB; do
      [ -f "$d/package.json" ] || continue
      if ! ls "$d"/jest.config.* >/dev/null 2>&1 && ! grep -q '"jest"' "$d/package.json"; then echo "  - $d: no jest config, skipped"; continue; fi
      echo "  - $d"; run_jest_in "$ROOT/$d" "$d" "$JEST_ARGS"
    done ;;
  vitest)
    newlog vitest
    [ -d node_modules ] || die "node_modules missing, run the package install"
    tmo npx --no-install vitest run --reporter=json --outputFile="$OUT" --maxWorkers="$MAX_WORKERS" >"$LOG" 2>&1
    collect jest vitest $? ;;
  node-test)
    newlog node
    [ -n "$NODE_TEST_GLOB" ] || die "NODE_TEST_GLOB not set"
    set -f; tmo node --test --test-reporter=tap "$NODE_TEST_GLOB" >"$OUT" 2>"$LOG"; rc=$?; set +f   # node expands the glob
    collect tap node-test $rc ;;
  go)
    newlog go
    # shellcheck disable=SC2086
    tmo go test -json $GO_PKGS >"$OUT" 2>"$LOG"
    collect go "go test" $? ;;
  pytest)
    newlog pytest
    case " $PYTEST_ARGS " in *" -x "*|*--maxfail*|*" --lf "*|*--last-failed*|*--continue-on-collection-errors*|*" -k "*|*" -m "*) die "PYTEST_ARGS may not limit or filter the run on pre-push" ;; esac
    "$PYTHON" -c "import pytest" 2>/dev/null || die "pytest not available for '$PYTHON' (set PYTHON in .test-gate.local.conf)"
    # shellcheck disable=SC2086
    tmo "$PYTHON" -m pytest -q -p no:cacheprovider --junitxml="$OUT" $PYTEST_ARGS >"$LOG" 2>&1; rc=$?
    case "$rc" in 0|1) collect junit pytest "$rc" ;; *) err "pytest exited $rc (interrupted/internal/usage/collection error) (log: $LOG)" ;; esac ;;
  frappe)
    newlog frappe
    [ -n "$FRAPPE_APP" ] || die "FRAPPE_APP not set in .test-gate.conf"
    [ -n "$FRAPPE_BENCH" ] && [ -n "$FRAPPE_SITE" ] || die "set FRAPPE_BENCH and FRAPPE_SITE in .test-gate.local.conf"
    benchapp="$(cd "$FRAPPE_BENCH/apps/$FRAPPE_APP" 2>/dev/null && pwd -P)"
    [ -n "$benchapp" ] || die "app '$FRAPPE_APP' not found in $FRAPPE_BENCH/apps"
    if [ "$benchapp" != "$(cd "$ROOT" && pwd -P)" ]; then
      [ "$(git -C "$benchapp" rev-parse HEAD 2>/dev/null)" = "$HEADSHA" ] && [ -z "$(git -C "$benchapp" status --porcelain 2>/dev/null)" ] \
        || die "bench app $benchapp is not this checkout at $HEADSHA (clean). Check out the pushed commit there first."
    fi
    (cd "$FRAPPE_BENCH" && tmo bench --site "$FRAPPE_SITE" run-tests --app "$FRAPPE_APP" --junit-xml-output "$OUT" >"$LOG" 2>&1); rc=$?
    collect junit "bench run-tests" "$rc"
    [ "$rc" -eq 0 ] || [ "$FAILED" -gt 0 ] || err "bench exited $rc with no failed tests (log: $LOG)" ;;
  custom)  # CUSTOM_CMD must print a line: GATE_TOTAL=<n> GATE_PASSED=<n>
    newlog custom
    eval "$CUSTOM_CMD" >"$LOG" 2>&1; rc=$?
    line="$(grep -E 'GATE_TOTAL=[0-9]+ GATE_PASSED=[0-9]+' "$LOG" | tail -1)"
    [ -n "$line" ] || die "custom runner printed no GATE_TOTAL/GATE_PASSED line (rc=$rc, log: $LOG)"
    t="$(echo "$line" | sed -E 's/.*GATE_TOTAL=([0-9]+).*/\1/')"; p="$(echo "$line" | sed -E 's/.*GATE_PASSED=([0-9]+).*/\1/')"
    [ "$p" -le "$t" ] || die "custom runner reported passed > total"
    PASSED=$((PASSED + p)); FAILED=$((FAILED + t - p))
    [ "$rc" -eq 0 ] || [ "$t" -gt "$p" ] || err "custom runner exited $rc with no failed tests (log: $LOG)" ;;
  *) die "unknown RUNNER '$RUNNER'" ;;
esac

[ -z "$ERRORS" ] || { printf 'test-gate: BLOCKED - runner errors:\n%s' "$ERRORS" >&2; exit 1; }
COUNTED=$((PASSED + FAILED))
[ "$COUNTED" -gt 0 ] || die "0 tests ran. Add tests first (Delivery Rule 6). Logs: $LOGDIR"
PCT="$(python3 -c "print(f'{$PASSED*100/$COUNTED:.2f}')")"
echo "test-gate: $PASSED passed, $FAILED failed, $SKIPPED skipped -> ${PCT}% (threshold ${THRESHOLD}%)"
if python3 -c "import sys; sys.exit(0 if $PASSED*100 >= $THRESHOLD*$COUNTED else 1)"; then
  echo "test-gate: PASS"; exit 0
fi
die "pass rate below ${THRESHOLD}% (Delivery Rule 6). Logs: $LOGDIR"
