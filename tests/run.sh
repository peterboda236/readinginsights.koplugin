#!/bin/sh
# Reading Insights - run every check.
#
#   ./tests/run.sh          from the plugin root, or from anywhere
#
# Needs lua5.1 and luac5.1 and nothing else: no KOReader, no device. What
# can't be covered this way is the drawing itself - anything under views/
# that builds widgets still has to be tried on a device.
#
# Exit status is 0 only if everything passed, so this can gate a commit.

set -e
cd "$(dirname "$0")/.."

for tool in lua5.1 luac5.1; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool not found - install Lua 5.1 (on Debian/Ubuntu: apt install lua5.1)"
        exit 2
    fi
done

failed=0
run() {
    echo ""
    echo "=============================================================="
    echo " $1"
    echo "=============================================================="
    if lua5.1 "$1"; then
        :
    else
        failed=1
    fi
}

set +e
run tests/static_checks.lua
run tests/test_modules.lua
run tests/test_chapterinfo.lua
run tests/test_records.lua

# The day-bounds arithmetic is timezone-dependent, so it is run under a
# timezone that actually observes DST rather than whatever the machine has.
echo ""
echo "=============================================================="
echo " tests/test_daybounds.lua (TZ=Europe/Budapest)"
echo "=============================================================="
if ! TZ=Europe/Budapest lua5.1 tests/test_daybounds.lua; then failed=1; fi
run tests/test_wiring.lua

echo ""
echo "=============================================================="
if [ "$failed" -eq 0 ]; then
    echo " ALL CHECKS PASSED"
else
    echo " SOMETHING FAILED - see above"
fi
echo "=============================================================="
exit "$failed"
