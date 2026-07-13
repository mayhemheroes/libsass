#!/usr/bin/env bash
#
# mayhem/build.sh — build libsass's fuzz target and its own unit-test suite.
#
# libsass is a C++ Sass compiler library built with a plain Makefile (`make static` ->
# lib/libsass.a). We build:
#   1) the library SANITIZED (+DWARF-3) and link the OSS-Fuzz harness
#      mayhem/data_context_fuzzer.cc against it -> /mayhem/data_context_fuzzer (libFuzzer)
#      plus /mayhem/data_context_fuzzer-standalone (run-once reproducer).
#   2) the project's own C++ unit tests (test/test_shared_ptr.cpp, test/test_util_string.cpp,
#      upstream's `make -C test test` suite) with NORMAL flags into build-tests/ so
#      mayhem/test.sh only RUNS them.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the environment (base image exports the defaults); fall back for a bare run.
# SANITIZER_FLAGS uses `=` on purpose: an explicit empty value builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "${SRC:-/mayhem}"

# SanitizerCoverage on the WHOLE library so libFuzzer/Mayhem get edge feedback from libsass
# code itself (not just the harness TU). `-fsanitize=fuzzer-no-link` adds the coverage
# instrumentation without pulling libFuzzer's main into every object; the harness link below
# adds `-fsanitize=fuzzer` (full engine), the standalone link adds `fuzzer-no-link` (cov runtime,
# no main — StandaloneFuzzTargetMain provides it). Only meaningful when sanitizers are on.
FUZZ_COV=""
[ -n "$SANITIZER_FLAGS" ] && FUZZ_COV="-fsanitize=fuzzer-no-link"

# 1) Build the PROJECT ITSELF sanitized (ASan+UBSan halting) + SanCov + DWARF-3, so the fuzzed
#    library code is instrumented — not just the harness. `make static` -> lib/libsass.a.
#    Idempotent: make only rebuilds what changed; safe to re-run offline.
make -j"$MAYHEM_JOBS" static BUILD=static CC="$CC" CXX="$CXX" \
  EXTRA_CFLAGS="$SANITIZER_FLAGS $FUZZ_COV $DEBUG_FLAGS" \
  EXTRA_CXXFLAGS="$SANITIZER_FLAGS $FUZZ_COV $DEBUG_FLAGS" \
  EXTRA_LDFLAGS="$SANITIZER_FLAGS"

# 2) The harness, twice: libFuzzer target + standalone run-once reproducer.
#    C++ harness: compile the C standalone driver as a C object first so its
#    LLVMFuzzerTestOneInput reference keeps C linkage.
# shellcheck disable=SC2086
$CXX -std=c++11 $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -Iinclude \
  mayhem/data_context_fuzzer.cc lib/libsass.a -lm \
  -o /mayhem/data_context_fuzzer
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
# shellcheck disable=SC2086
$CXX -std=c++11 $SANITIZER_FLAGS $FUZZ_COV $DEBUG_FLAGS -Iinclude \
  mayhem/data_context_fuzzer.cc /tmp/standalone_main.o lib/libsass.a -lm \
  -o /mayhem/data_context_fuzzer-standalone

# 3) The project's OWN unit-test suite (upstream `make -C test test` compiles+runs these;
#    we compile here with upstream's normal flags so test.sh only RUNS them).
#    Mirrors test/Makefile exactly: each test compiles the src files it exercises.
mkdir -p build-tests
# shellcheck disable=SC2086
$CXX -I include/ -g -O1 -fno-omit-frame-pointer -std=c++11 $COVERAGE_FLAGS \
  src/memory/allocator.cpp src/memory/shared_ptr.cpp test/test_shared_ptr.cpp \
  -o build-tests/test_shared_ptr
# shellcheck disable=SC2086
$CXX -I include/ -g -O1 -fno-omit-frame-pointer -std=c++11 $COVERAGE_FLAGS \
  src/memory/allocator.cpp src/util_string.cpp test/test_util_string.cpp \
  -o build-tests/test_util_string

echo "build.sh: built /mayhem/data_context_fuzzer(+standalone) and build-tests/{test_shared_ptr,test_util_string}"
