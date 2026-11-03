#!/usr/bin/env bash
#
# mayhem/build.sh — build libSQL's fuzz harnesses (fuzz_sql, fuzz_vector, dbfuzz2) and the tcl test oracle.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
B="$SRC/mayhem/build"          # gitignored (mayhem/.gitignore): removed by `git clean -ffdX`, recreated here
SQLITE_SRC="$SRC/libsql-sqlite3"
mkdir -p "$B/test" "$B/fuzz"

# 1) Oracle build: libSQL's own configure + make with its NORMAL flags (no sanitizer, no -gdwarf-3),
#    out-of-tree so the source tree stays pristine. Yields build/test/{sqlite3,testfixture} and the
#    amalgamation (sqlite3.c/.h) that step 2 instruments. test.sh only RUNS these.
CFG_ENV=()
[ -z "$COVERAGE_FLAGS" ] || CFG_ENV=(CFLAGS="-g -O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS")
if [ ! -f "$B/test/Makefile" ]; then
  (cd "$B/test" && env -u CFLAGS -u LDFLAGS -u CPPFLAGS "${CFG_ENV[@]}" "$SQLITE_SRC/configure" --disable-static)
fi
make -C "$B/test" -j"$MAYHEM_JOBS" sqlite3 testfixture

# 2) Fuzz build: the whole library (amalgamation) compiled with $SANITIZER_FLAGS + DWARF 3, plus
#    SanCov (fuzzer-no-link) so the library — not just the harness TU — reports edges.
#    sqlite3.o        : production-like options (fuzz_sql, fuzz_vector)
#    sqlite3-debug.o  : -DSQLITE_DEBUG asserts, as dbfuzz2.c's own build recipe requires
FEATURES=(-DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_ENABLE_FTS3 -DSQLITE_ENABLE_FTS3_PARENTHESIS
  -DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_GEOPOLY
  -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_BYTECODE_VTAB -DSQLITE_ENABLE_STMTVTAB -DSQLITE_ENABLE_DBPAGE_VTAB
  -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_ENABLE_STAT4 -DSQLITE_ENABLE_SESSION -DSQLITE_ENABLE_PREUPDATE_HOOK)
CFLAGS_FUZZ="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1"
# shellcheck disable=SC2086
$CC $CFLAGS_FUZZ "${FEATURES[@]}" -I"$B/test" -c "$B/test/sqlite3.c" -o "$B/fuzz/sqlite3.o" &
# shellcheck disable=SC2086
$CC $CFLAGS_FUZZ "${FEATURES[@]}" -DSQLITE_DEBUG -I"$B/test" -c "$B/test/sqlite3.c" -o "$B/fuzz/sqlite3-debug.o" &
wait %1 %2

# LeakSanitizer off at build time (ASan + UBSan stay on)
# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$B/fuzz/lsan_off.o"
# C run-once driver for the *-standalone reproducers
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o "$B/fuzz/standalone_main.o"

LIBS="-lm -lpthread"
# link_target <name> <source.c> <sqlite3 object> [extra cc flags...]
link_target() {
  local name="$1" src="$2" obj="$3"; shift 3
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$@" -I"$B/test" "$src" "$obj" "$B/fuzz/lsan_off.o" $LIBS -o "/mayhem/$name"
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS "$@" -I"$B/test" "$src" "$obj" "$B/fuzz/standalone_main.o" "$B/fuzz/lsan_off.o" $LIBS -o "/mayhem/$name-standalone"
}
link_target fuzz_sql    "$SRC/mayhem/harness/fuzz_sql.c" "$B/fuzz/sqlite3.o"
link_target fuzz_vector "$SRC/mayhem/harness/fuzz_sql.c" "$B/fuzz/sqlite3.o" -DFUZZ_VECTOR
link_target dbfuzz2     "$SQLITE_SRC/test/dbfuzz2.c"     "$B/fuzz/sqlite3-debug.o"
