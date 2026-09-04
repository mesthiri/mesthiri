#!/usr/bin/env bash
# Runs every module's test file. One non-zero exit fails the lot.
#
# The ecosystem libraries are found via sibling checkouts by default, which is
# how this workspace is laid out. Override with MESTHIRI_LIBS for another
# arrangement, e.g. once `thottam install` has placed them centrally.
set -uo pipefail
cd "$(dirname "$0")/.."

: "${MESTHIRI_LIBS:=../kaappi-json/lib ../kaappi-http/lib ../kaappi-net/lib}"
libargs=(--lib-path ./lib)
for l in $MESTHIRI_LIBS; do libargs+=(--lib-path "$l"); done

# A raised error inside a test is NOT a failing exit code: kaappi prints it,
# skips the rest of that top-level form, and carries on — so the assertion
# never runs, the counters never see it, and the file still exits 0. That
# happened: `validate-harnesses` was called with its arguments swapped, the
# error scrolled past in stderr, and the suite reported 0 failed while the
# check it was named for had not executed. So stderr is inspected too.
status=0
for t in tests/test-*.scm; do
  err=$(mktemp)
  kaappi "${libargs[@]}" "$t" 2> >(tee "$err" >&2) || status=1
  if grep -q 'error\[KP' "$err"; then
    echo "  ERRORED: $t raised — assertions after it did not run"
    status=1
  fi
  rm -f "$err"
done

# Static checks. These cover the seams the .scm tests cannot see: a module
# can be fully tested and still not be wired into the entry point.
echo
echo "static checks"
./scripts/check-handlers.sh || status=1

if [ $status -ne 0 ]; then echo; echo "SUITE FAILED"; fi
exit $status
