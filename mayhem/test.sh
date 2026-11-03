#!/usr/bin/env bash
#
# mayhem/test.sh — RUN libSQL's own tcl test files + known-answer SQL probes (both built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

B="$SRC/mayhem/build/test"
T="$B/testfixture"
SH="$B/sqlite3"
TESTDIR="$SRC/libsql-sqlite3/test"
[ -x "$T" ]  || { echo "FATAL: $T missing (mayhem/build.sh builds it)" >&2; emit_ctrf "libsql-tcl+kat" 0 1; exit 1; }
[ -x "$SH" ] || { echo "FATAL: $SH missing (mayhem/build.sh builds it)" >&2; emit_ctrf "libsql-tcl+kat" 0 1; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/libsql-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

PASSED=0 FAILED=0

# 1) Upstream tcl test files, each run through testfixture; parse the harness's own
#    "N errors out of M tests" summary. A missing summary (crash, or the binary neutered) is a failure.
run_tcl_test() {
  local name="$1" script="$2" out errs total
  out="$(timeout 900 "$T" "$script" 2>&1)"
  if [[ "$out" =~ ([0-9]+)\ errors\ out\ of\ ([0-9]+)\ tests ]]; then
    errs="${BASH_REMATCH[1]}" total="${BASH_REMATCH[2]}"
    if [ "$total" -lt 1 ]; then
      echo "FAIL $name: ran 0 tests" >&2; FAILED=$((FAILED+1)); return
    fi
    PASSED=$((PASSED + total - errs)); FAILED=$((FAILED + errs))
    echo "$name: $errs errors out of $total tests"
    [ "$errs" -eq 0 ] || printf '%s\n' "$out" | grep -E '^!|Failures on these tests' >&2
  else
    echo "FAIL $name: no 'errors out of' summary" >&2; printf '%s\n' "$out" | tail -5 >&2
    FAILED=$((FAILED+1))
  fi
}

for t in select1 select2 expr func insert update delete trigger1 alter where join json101 vtab1 libsql_alter; do
  run_tcl_test "$t" "$TESTDIR/$t.test"
done

# libsql_vector.test has no finish_test of its own; wrap it so tester.tcl prints the summary.
cat > vector_wrap.tcl <<TCL
set argv0 $TESTDIR/libsql_vector.test
source $TESTDIR/libsql_vector.test
finish_test
TCL
run_tcl_test libsql_vector "$WORK/vector_wrap.tcl"

# 2) Known-answer probes through the built shell: fixed SQL -> exact expected output.
kat() {
  local desc="$1" sql="$2" want="$3" got
  got="$("$SH" -batch :memory: "$sql" 2>&1)"
  if [ "$got" = "$want" ]; then
    PASSED=$((PASSED+1)); echo "kat ok: $desc"
  else
    FAILED=$((FAILED+1)); echo "kat FAIL: $desc: want [$want] got [$got]" >&2
  fi
}
kat arithmetic   "SELECT 1+2, upper('abc'), length('hello');" "3|ABC|5"
kat json         "SELECT json_extract('{\"a\":[1,2,{\"b\":7}]}', '\$.a[2].b');" "7"
kat recursive-cte "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<100) SELECT sum(x) FROM c;" "5050"
kat vector-roundtrip "SELECT vector_extract(vector('[1,2,3]')), hex(vector32('[1,2]'));" "[1,2,3]|0000803F00000040"
kat vector-cos   "SELECT vector_distance_cos('[1,0]','[0,1]'), vector_distance_cos('[1,1]','[1,1]');" "1.0|0.0"
kat vector-l2    "SELECT vector_distance_l2('[0,0]','[3,4]');" "5.0"
kat vector-index "CREATE TABLE t(id INTEGER PRIMARY KEY, v FLOAT32(2)); CREATE INDEX ti ON t(libsql_vector_idx(v, 'metric=l2')); INSERT INTO t VALUES(1,vector('[1,1]')),(2,vector('[9,9]')),(3,vector('[2,1]')),(4,vector('[5,5]')); SELECT group_concat(id) FROM (SELECT id FROM vector_top_k('ti', '[1,1]', 3));" "1,3,4"

echo "libsql tests: passed=$PASSED failed=$FAILED"
cd "$SRC"
emit_ctrf "libsql-tcl+kat" "$PASSED" "$FAILED" 0
