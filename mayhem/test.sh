#!/usr/bin/env bash
#
# mayhem/test.sh — RUN libsass's own unit-test suite (prebuilt by mayhem/build.sh).
#
# Upstream's `make -C test test` suite: build-tests/test_shared_ptr (11 tests) and
# build-tests/test_util_string (16 tests). Each binary runs named test functions that
# assert behavior (refcount lifecycle, string normalization known-answers) and prints
# "<argv0>: Passed: <n>, failed: <m>." to stderr, exiting with the failure count.
# We parse those counts; a neutered exit(0) binary prints no summary and is counted
# as failing every one of its tests (anti-reward-hack).
#
# NOTE: upstream's `make test` sass-spec suite is an EXTERNAL repo (sass/sass-spec)
# whose ruby runner was deleted upstream in Dec 2022 and whose HEAD spec content has
# known non-conformances vs libsass — it is not part of this repo and is not run here.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

passed=0; failed=0

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" p="$2" f="$3" s="${4:-0}" pe="${5:-0}" o="${6:-0}"
  local tests=$(( p + f + s + pe + o ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": { "tests": $tests, "passed": $p, "failed": $f, "pending": $pe, "skipped": $s, "other": $o }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$p" "$f" "$pe" "$s" "$o"
  [ "$f" -eq 0 ]
}

# run_suite <binary> <expected-test-count>
run_suite() {
  local bin="$1" expect="$2" out p f
  if [ ! -x "$bin" ]; then
    echo "test.sh: $bin missing — build.sh must build it (not rebuilding here)" >&2
    failed=$((failed + expect)); return
  fi
  out="$("$bin" 2>&1)" || true
  echo "$out"
  p="$(printf '%s\n' "$out" | sed -n 's/.*Passed: \([0-9]*\), failed: \([0-9]*\).*/\1/p' | tail -1)"
  f="$(printf '%s\n' "$out" | sed -n 's/.*Passed: \([0-9]*\), failed: \([0-9]*\).*/\2/p' | tail -1)"
  if [ -z "$p" ] || [ -z "$f" ] || [ $(( p + f )) -ne "$expect" ]; then
    # no/short summary (e.g. a neutered binary): every expected test counts as failed
    failed=$((failed + expect)); return
  fi
  passed=$((passed + p)); failed=$((failed + f))
}

run_suite build-tests/test_shared_ptr 11
run_suite build-tests/test_util_string 16

emit_ctrf libsass-unit-tests "$passed" "$failed"
