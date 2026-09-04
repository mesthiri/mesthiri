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

status=0
for t in tests/test-*.scm; do
  kaappi "${libargs[@]}" "$t" || status=1
done

if [ $status -ne 0 ]; then echo; echo "SUITE FAILED"; fi
exit $status
