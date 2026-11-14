#!/bin/zsh
# All tests on a BSC fork at a pinned block (cached after the first run). Usage: scripts/test.sh [block]
cd "${0:A:h}/../contracts" || exit 1
set -a; source ./.env; set +a
FORK_BLOCK="${1:-133013326}" forge test -j 2 2>&1
