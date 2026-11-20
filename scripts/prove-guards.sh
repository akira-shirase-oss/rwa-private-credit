#!/usr/bin/env bash
# Every guard in the contracts is proven by a test that fails when the guard is removed
# (END_GOAL cases 1 and 9).
#
# Each protection in contracts/src carries a marker, `// GUARD(name)`, on the line that
# enforces it (or on a line of its own above the function whose modifier enforces it). For every marker this script removes the protection in a scratch copy (one
# substitution on that line) and runs the tests listed for it, which must then ALL FAIL as
# tests (a build error is not a proof). A marker without a mutation below, or a mutation
# whose marker is gone, fails the script, and so does a state-changing external function
# with no marker: GUARD(name) when it is privileged, AUTH(reason) when it authorises in its
# body or acts only on the caller, OPEN(reason) when anyone may call it.
#
#   scripts/prove-guards.sh [--out FILE]   (FILE: a JSON record; never names the machine)
#
# Needs forge 1.10.0 (scripts/install-foundry.sh target/tools/bin) and the contracts/lib
# submodules. Uses the `prove` profile (fewer fuzz and invariant runs, same tests).
set -euo pipefail
case "${1:-}" in -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;; esac
cd "$(dirname "$0")/.."
here="$PWD"
out=""
case "${1:-}" in
  "") ;;
  --out) out="${2:?--out needs a file}" ;;
  *) echo "prove-guards.sh: unknown argument $1 (see --help)" >&2; exit 2 ;;
esac
[ -d target/tools/bin ] && PATH="$PWD/target/tools/bin:$PATH"
command -v forge >/dev/null || { echo "prove-guards.sh: forge not found: scripts/install-foundry.sh target/tools/bin" >&2; exit 2; }
[ -f contracts/lib/forge-std/src/Test.sol ] || { echo "prove-guards.sh: contracts/lib is empty: git submodule update --init --recursive" >&2; exit 2; }

# name|file (under contracts/src)|pattern=>replacement (a Python regex on the marked line)|tests (comma-separated)
mutations=(
  "compliance-country-council|ComplianceModule.sol| onlyCouncil=>|test_unauthorised_set_country_allowed_refused"
  "compliance-max-holders-council|ComplianceModule.sol| onlyCouncil=>|test_unauthorised_set_max_holders_refused"
  "compliance-min-holding-council|ComplianceModule.sol| onlyCouncil=>|test_unauthorised_set_min_holding_refused"
  "compliance-lockup-council|ComplianceModule.sol| onlyCouncil=>|test_unauthorised_set_lockup_end_refused"
  "sender-registered|ComplianceModule.sol|if \(!registered\)=>if (!registered \&\& !sending)|test_sender_removed_refused"
  "receiver-registered|ComplianceModule.sol|if \(!registered\)=>if (!registered \&\& sending)|test_receiver_removed_refused_on_every_path,test_receiver_never_registered_refused_on_every_path"
  "sender-kyc|ComplianceModule.sol|if \(kycExpiry <= block.timestamp\)=>if (kycExpiry <= block.timestamp \&\& !sending)|test_sender_kyc_expired_refused"
  "receiver-kyc|ComplianceModule.sol|if \(kycExpiry <= block.timestamp\)=>if (kycExpiry <= block.timestamp \&\& sending)|test_receiver_kyc_expired_refused_on_every_path"
  "sender-frozen|ComplianceModule.sol|if \(frozen\)=>if (frozen \&\& !sending)|test_sender_frozen_refused"
  "receiver-frozen|ComplianceModule.sol|if \(frozen\)=>if (frozen \&\& sending)|test_receiver_frozen_refused_on_every_path"
  "sender-country|ComplianceModule.sol|return sending \? .*;=>if (!sending) return Refusal.ReceiverCountryNotAllowed;|test_sender_country_refused"
  "receiver-country|ComplianceModule.sol|return sending \? .*;=>if (sending) return Refusal.SenderCountryNotAllowed;|test_receiver_country_refused_on_every_path"
  "sender-checked|ComplianceModule.sol|r = partyRefusal\(from, true\);=>r = Refusal.None;|test_sender_removed_refused,test_sender_frozen_refused,test_sender_country_refused"
  "lockup|ComplianceModule.sol|block\.timestamp < lockupEnd=>false|test_sender_inside_lockup_refused"
  "sender-minimum|ComplianceModule.sol|fromAfter != 0 \&\& =>false \&\& |test_sender_left_under_minimum_refused"
  "receiver-checked|ComplianceModule.sol|r = partyRefusal\(to, false\);=>r = Refusal.None;|test_path_transfer_refuses_every_ineligible_receiver,test_path_transfer_from_refuses_every_ineligible_receiver,invariant_destinations_always_eligible"
  "forced-receiver-checked|ComplianceModule.sol|r = partyRefusal\(to, false\);=>r = forced ? Refusal.None : partyRefusal(to, false);|test_path_forced_refuses_every_ineligible_receiver,test_path_recover_refuses_every_ineligible_receiver"
  "mint-receiver-checked|ComplianceModule.sol|r = partyRefusal\(to, false\);=>r = from == address(0) ? Refusal.None : partyRefusal(to, false);|test_path_mint_refuses_every_ineligible_receiver,test_path_batch_mint_refuses_every_ineligible_receiver"
  "max-holders|ComplianceModule.sol|newHolder \&\& holdersAfter > maxHolders=>false|test_receiver_over_max_holders_refused_on_every_path"
  "receiver-minimum|ComplianceModule.sol|toAfter != 0 \&\& toAfter < minHolding=>false|test_receiver_under_minimum_holding_refused_on_every_path"
  "council-propose-member|Council.sol|onlyMember=>|test_unauthorised_propose_refused"
  "council-approve-member|Council.sol| onlyMember=>|test_unauthorised_approve_refused"
  "council-execute-member|Council.sol| onlyMember=>|test_unauthorised_execute_refused"
  "council-delay|Council.sol|if \(block\.timestamp < p\.eta\).*;=>|test_execution_before_the_delay_is_refused"
  "council-expiry|Council.sol|if \(block\.timestamp > p\.eta \+ GRACE_PERIOD\).*;=>|test_execution_after_the_grace_period_is_refused"
  "council-data|Council.sol|if \(keccak256\(data\) != p\.dataHash\).*;=>|test_other_calldata_is_refused"
  "council-replay|Council.sol|p\.executed = true;=>|test_replay_is_refused"
  "council-members-self|Council.sol| onlySelf=>|test_unauthorised_set_members_refused"
  "council-delay-self|Council.sol| onlySelf=>|test_unauthorised_set_delay_refused"
  "council-distinct|Council.sol|if \(hasApproved\[id\]\[member\]\).*;=>|test_a_single_member_cannot_reach_the_threshold"
  "council-threshold|Council.sol|approvals == threshold=>approvals == 1|test_a_single_member_cannot_reach_the_threshold,test_no_single_key_moves_a_holders_tokens"
  "council-executed-once|Council.sol|if \(p\.executed\).*;=>|test_replay_is_refused"
  "council-epoch|Council.sol|if \(p\.epoch != epoch\).*;=>|test_a_membership_change_voids_pending_proposals"
  "council-min-threshold|Council.sol|threshold_ < MIN_THRESHOLD=>false|test_the_council_refuses_weak_or_duplicate_membership"
  "council-unique-members|Council.sol|isMember\[m\]\)=>false)|test_the_council_refuses_weak_or_duplicate_membership"
  "council-min-delay|Council.sol|delay_ < MIN_DELAY=>false|test_the_council_refuses_weak_or_duplicate_membership"
  "council-is-contract|CouncilGoverned.sol|council_\.code\.length == 0=>false|test_a_weak_council_is_refused_at_deployment"
  "council-strength|CouncilGoverned.sol|if \(.*\) revert=>if (false) revert|test_a_weak_council_is_refused_at_deployment"
  "grant-role|CouncilGoverned.sol| onlyCouncil=>|test_unauthorised_grant_role_refused"
  "revoke-role|CouncilGoverned.sol| onlyCouncil=>|test_unauthorised_revoke_role_refused"
  "registry-register-role|IdentityRegistry.sol|onlyRole\(REGISTRAR_ROLE\)=>|test_unauthorised_register_refused"
  "registry-keeps-frozen|IdentityRegistry.sol|id\.registered = true;=>id.registered = true; id.frozen = false;|test_freeze_survives_removal_and_re_registration"
  "registry-kyc-role|IdentityRegistry.sol| onlyRole\(REGISTRAR_ROLE\)=>|test_unauthorised_update_kyc_refused"
  "registry-country-role|IdentityRegistry.sol| onlyRole\(REGISTRAR_ROLE\)=>|test_unauthorised_update_country_refused"
  "registry-remove-role|IdentityRegistry.sol| onlyRole\(REGISTRAR_ROLE\)=>|test_unauthorised_remove_refused"
  "registry-freeze-role|IdentityRegistry.sol| onlyRoleOrCouncil\(AGENT_ROLE\)=>|test_unauthorised_freeze_refused"
  "registry-unfreeze-council|IdentityRegistry.sol| onlyCouncil=>|test_unauthorised_unfreeze_refused"
  "registry-kyc-bound|IdentityRegistry.sol|revert BadKycExpiry\(kycExpiry\);=>|test_registry_bounds_the_kyc_expiry"
  "token-mint-role|PoolToken.sol| onlyRole\(MINTER_ROLE\)=>|test_unauthorised_mint_refused"
  "path-mint|PoolToken.sol|_mint\(to, amount\);=>ERC20._update(address(0), to, amount);|test_path_mint_refuses_every_ineligible_receiver"
  "token-batch-mint-role|PoolToken.sol| onlyRole\(MINTER_ROLE\)=>|test_unauthorised_batch_mint_refused"
  "path-batch-mint|PoolToken.sol|_mint\(to\[i\], amounts\[i\]\);=>ERC20._update(address(0), to[i], amounts[i]);|test_path_batch_mint_refuses_every_ineligible_receiver"
  "path-batch-transfer|PoolToken.sol|_transfer\(msg\.sender, to\[i\], amounts\[i\]\);=>ERC20._update(msg.sender, to[i], amounts[i]);|test_path_batch_transfer_refuses_every_ineligible_receiver"
  "token-pause-role|PoolToken.sol| onlyRoleOrCouncil\(AGENT_ROLE\)=>|test_unauthorised_pause_refused"
  "token-unpause-council|PoolToken.sol| onlyCouncil=>|test_unauthorised_unpause_refused"
  "token-unfreeze-council|PoolToken.sol|_onlyCouncil\(\);=>|test_unauthorised_unfreeze_tokens_refused"
  "token-freeze-role|PoolToken.sol|_onlyRoleOrCouncil\(AGENT_ROLE\);=>|test_unauthorised_freeze_tokens_refused"
  "token-forced-council|PoolToken.sol| onlyCouncil=>|test_unauthorised_forced_transfer_refused,test_no_single_key_moves_a_holders_tokens"
  "path-forced|PoolToken.sol|_transfer\(from, to, amount\);=>ERC20._update(from, to, amount);|test_path_forced_refuses_every_ineligible_receiver"
  "token-recover-council|PoolToken.sol| onlyCouncil=>|test_unauthorised_recover_wallet_refused,test_no_single_key_moves_a_holders_tokens"
  "recover-same-investor|PoolToken.sol|revert NotSameInvestor\(lost, replacement\);=>|test_recover_refuses_another_investors_wallet"
  "path-recover|PoolToken.sol|_transfer\(lost, replacement, amount\);=>ERC20._update(lost, replacement, amount);|test_path_recover_refuses_every_ineligible_receiver"
  "token-hook|PoolToken.sol|if \(r != Refusal\.None\) _revertRefusal\(from, to, value, r\);=>|test_path_transfer_refuses_every_ineligible_receiver,test_path_transfer_from_refuses_every_ineligible_receiver,test_sender_frozen_refused,invariant_destinations_always_eligible"
  "paused|PoolToken.sol|paused \&\& !forced=>false|test_paused_refuses_holder_paths_and_mints"
  "frozen-tokens|PoolToken.sol|!forced \&\& value > _unfrozen\(from, fromBalance\)=>false|test_sender_frozen_tokens_refused"
  "batch-bound|PoolToken.sol|if \(toLength > MAX_BATCH\).*;=>|test_batches_are_bounded_and_matched"
)

# Every marker has exactly one mutation, and every mutation a marker.
found="$(grep -rhoE --include='*.sol' 'GUARD\([a-z-]+\)' contracts/src | sed 's/GUARD(\(.*\))/\1/' | sort)"
defined="$(printf '%s\n' "${mutations[@]}" | cut -d'|' -f1 | sort)"
if [ "$found" != "$defined" ]; then
  echo "error: markers and mutations differ (or a name is used twice):" >&2
  diff <(echo "$found") <(echo "$defined") >&2 || true
  exit 1
fi

# Every state-changing external or public function says how it is authorised.
python3 -I - contracts/src <<'PY'
import pathlib, re, sys
bad = []
for path in sorted(pathlib.Path(sys.argv[1]).rglob("*.sol")):
    if "interfaces" in path.parts:
        continue
    lines = path.read_text().split("\n")
    for i, line in enumerate(lines):
        if not re.match(r"\s*function \w+\(", line):
            continue
        j = i
        while "{" not in lines[j] and ";" not in lines[j]:
            j += 1
        sig = " ".join(lines[i : j + 1])
        if not re.search(r"\b(external|public)\b", sig) or re.search(r"\b(view|pure)\b", sig):
            continue
        context = " ".join(lines[max(0, i - 2) : j + 1])
        if not re.search(r"(GUARD|AUTH|OPEN)\([a-z-]+\)", context):
            bad.append(f"{path.name}:{i + 1}: {line.strip()}")
if bad:
    sys.exit("error: state-changing entry points with no GUARD/AUTH/OPEN marker:\n  " + "\n  ".join(bad))
PY

work="$(mktemp -d "${TMPDIR:-/tmp}/rwa-guards.XXXXXX")"
trap 'rm -rf "$work"' EXIT
(cd contracts && tar --exclude ./lib --exclude ./out --exclude ./cache -cf - .) | tar -xf - -C "$work"
ln -s "$here/contracts/lib" "$work/lib"
export FOUNDRY_PROFILE=prove

mutate() { # file marker pattern replacement
  python3 -I - "$work/src/$1" "$2" "$3" "$4" <<'PY'
import re, sys
path, marker, pattern, replacement = sys.argv[1:]
lines = open(path).read().split("\n")
tag = f"GUARD({marker})"
changed = 0
for i, line in enumerate(lines):
    if tag not in line:
        continue
    # A marker on a line of its own marks the function declared below it.
    targets = range(i + 1, min(i + 4, len(lines))) if line.strip().startswith("//") else [i]
    for t in targets:
        new = re.sub(pattern, lambda _: replacement, lines[t], count=1)
        if new != lines[t]:
            lines[t] = new
            changed += 1
            break
if changed != 1:
    sys.exit(f"the mutation for {marker} changed {changed} lines, not one")
open(path, "w").write("\n".join(lines))
PY
}

(cd "$work" && forge build --offline -q) || { echo "error: the unmutated contracts do not build" >&2; exit 1; }
failures=0
results=()
for row in "${mutations[@]}"; do
  IFS='|' read -r name file subst tests <<<"$row"
  pattern="${subst%%=>*}"
  replacement="${subst#*=>}"
  replacement="${replacement//\\&/&}"
  expected=$(tr ',' '\n' <<<"$tests" | wc -l)
  cp "$here/contracts/src/$file" "$work/src/$file"
  mutate "$file" "$name" "$pattern" "$replacement"
  started=$(date +%s)
  set +e
  output="$(cd "$work" && forge test --offline --force --match-test "^(${tests//,/|})\\(" 2>&1)"
  status=$?
  set -e
  seconds=$(( $(date +%s) - started ))
  cp "$here/contracts/src/$file" "$work/src/$file"
  summary="$(grep -E '^Ran [0-9]+ test suites?' <<<"$output" | tail -1 || true)"
  passed="$(sed -nE 's/.*: ([0-9]+) tests passed, ([0-9]+) failed.*/\1/p' <<<"$summary")"
  failed="$(sed -nE 's/.*: ([0-9]+) tests passed, ([0-9]+) failed.*/\2/p' <<<"$summary")"
  if [ "$status" -ne 0 ] && [ "$passed" = 0 ] && [ "$failed" = "$expected" ]; then
    verdict=proven
    printf '  proven   %-32s %s test(s) fail without it (%ss)\n' "$name" "$expected" "$seconds"
  elif [ -z "$summary" ]; then
    verdict=broken
    failures=$((failures + 1))
    printf '  BROKEN   %-32s the mutation did not build or no test ran:\n%s\n' "$name" "$(tail -15 <<<"$output")"
  else
    verdict=unproven
    failures=$((failures + 1))
    printf '  UNPROVEN %-32s %s of %s tests still pass without it: %s\n' "$name" "${passed:-?}" "$expected" "$summary"
  fi
  results+=("{\"guard\":\"$name\",\"tests\":$expected,\"verdict\":\"$verdict\",\"seconds\":$seconds}")
done

if [ -n "$out" ]; then
  commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  dirty=false; git diff --quiet HEAD -- contracts 2>/dev/null || dirty=true
  load="$(uptime | sed 's/.*load averages*: *//')"
  mkdir -p "$(dirname "$out")"
  printf '{"proof":"guards","commit":"%s","tree_dirty":%s,"load_average":"%s","os":"%s","results":[%s]}\n' \
    "$commit" "$dirty" "$load" "$(uname -sr)" "$(IFS=,; echo "${results[*]}")" >"$out"
  echo "record: $out"
fi
if (( failures )); then
  echo "error: $failures of ${#mutations[@]} guards are not proven" >&2
  exit 1
fi
echo "guards ok: all ${#mutations[@]} guards are proven by tests that fail without them"
