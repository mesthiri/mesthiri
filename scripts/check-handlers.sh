#!/usr/bin/env bash
# Every command in the command table must have a handler registered.
#
# `/fix` was in `command-table` and in `all-stages` from M7, its module was
# written and tested, and no handler was ever registered for it — so a typed
# `/fix` parsed, passed authorization, hit the `no-handler` branch, and
# posted nothing at all. The module's tests all passed: they test the
# module, and the wiring is not in the module.
#
# This compares the two lists mechanically, because reading them side by
# side is exactly what nobody does.
set -euo pipefail
cd "$(dirname "$0")/.."

stages=$(grep -oE '\(([a-z]+) +([a-z]+) +(issue|pull-request|either) +([a-z]+)\)' \
           lib/mesthiri/command.sld | awk '{print $2}' | sort -u)

fail=0
for st in $stages; do
  if ! grep -q "(cons '$st " mesthiri.scm; then
    echo "FAIL: command stage '$st' has no handler registered in mesthiri.scm"
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "  all command stages have handlers: $(echo "$stages" | tr '\n' ' ')"
fi
exit "$fail"
