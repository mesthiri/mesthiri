#!/usr/bin/env bash
# Runs every module's tests. One non-zero exit fails the lot.
set -uo pipefail
cd "$(dirname "$0")/.."
status=0
for t in tests/test-*.scm; do
  kaappi --lib-path ./lib "$t" || status=1
done
exit $status
