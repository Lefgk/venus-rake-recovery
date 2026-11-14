#!/bin/zsh
# Full rescue on a BSC fork, pinned block (cached after the first run). Usage: scripts/simulate.sh [block]
cd "${0:A:h}/../contracts" || exit 1
set -a; source ./.env; set +a
forge script script/simulation/SimulateVIP.s.sol --fork-url "$BSC_RPC_URL" --fork-block-number "${1:-133013326}" 2>&1 | grep -v -E '^\s*$'
