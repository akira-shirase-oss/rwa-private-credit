#!/usr/bin/env bash
# The contracts gate: the pinned forge, forge fmt --check, the build with sizes, then the
# unit, fuzz (10,000 runs per property) and invariant tests (10,000 runs x depth 32 of
# destinations_always_eligible). The guard mutation proofs are scripts/prove-guards.sh.
#
#   scripts/check-contracts.sh
#
# Needs forge 1.10.0 (scripts/install-foundry.sh target/tools/bin) and the contracts/lib
# submodules (git submodule update --init --recursive).
set -euo pipefail
case "${1:-}" in -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;; esac
[ $# -eq 0 ] || { echo "check-contracts.sh: takes no arguments (see --help)" >&2; exit 2; }
cd "$(dirname "$0")/.."
[ -d target/tools/bin ] && PATH="$PWD/target/tools/bin:$PATH"
command -v forge >/dev/null || { echo "check-contracts.sh: forge not found: scripts/install-foundry.sh target/tools/bin" >&2; exit 2; }
[ -f contracts/lib/forge-std/src/Test.sol ] || { echo "check-contracts.sh: contracts/lib is empty: git submodule update --init --recursive" >&2; exit 2; }
forge --version | head -1 | grep -q 'forge Version: 1.10.0' || { echo "check-contracts.sh: forge is not the pinned 1.10.0" >&2; exit 2; }
for lib in forge-std:f3dae6e6ee381f25eb6a246f7da9b85c91a68219 openzeppelin-contracts:cab19933c33c2ad1d4c7a84864a3601dddfd16f3; do
  got="$(git -C "contracts/lib/${lib%%:*}" rev-parse HEAD)"
  [ "$got" = "${lib#*:}" ] || { echo "check-contracts.sh: contracts/lib/${lib%%:*} is pinned at $got, not ${lib#*:}" >&2; exit 2; }
done
cd contracts
forge fmt --check
forge build --sizes
forge test
