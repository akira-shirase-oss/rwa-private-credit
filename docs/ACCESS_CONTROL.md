# Access control (M1: registry, compliance, token)

Who may do what to the identity registry, the compliance module and the pool token, and
the process that guards every action that can move a holder's tokens. The tests that
prove each line are named; `scripts/prove-guards.sh` removes each guard in turn and
requires its tests to fail (CI job `guards`).

## The council: the only path to a holder's tokens

`Council` is an M-of-N multisig with a timelock, written for this repository:

- **Members:** 3 to 16 distinct non-zero addresses, never the council itself; **threshold
  2 <= M < N** (`BadThreshold`, `BadMembers`): at M == N one member would be the `N - M + 1`
  that cancels a change of the council, so it could never be removed
  (`test_the_threshold_is_below_the_member_count`, `test_the_council_is_never_its_own_member`).
- **Delay:** between 1 day and 30 days; a queued call is executable for a 14-day grace
  period after its delay, then expires.
- **Process:** a member proposes `target.call(data)` with a non-zero `reasonCode` (the
  hash of the off-chain case record: never personal data) and the proposal counts as
  that member's approval; other members approve; at M approvals it is queued; after the
  delay any member executes it, with exactly the proposed bytes, once.
- **Stopping a call:** a member withdraws its own approval with `revokeApproval` until
  the call queues; after that, any member stops a call to another contract with
  `cancel` at any time before it executes, and it can never be approved or executed
  again. A call to the council itself (`setMembers`, `setDelay`) takes `N - M + 1`
  distinct members to cancel, the fewest that M approvals cannot outvote, so one member
  cannot block its own removal. A member that cancels everything is removed through
  `setMembers`: containing a compromised agent or registrar whose revocation one member
  cancels takes two delays, the removal and then the revocation
  (`test_a_member_cancelling_a_revocation_is_removed_and_the_revocation_executes`). Proven by `test_a_member_cancels_a_queued_call_before_execution`,
  `test_a_revoked_approval_does_not_count`,
  `test_a_single_member_cannot_cancel_the_councils_own_change`,
  `test_n_minus_m_plus_one_members_cancel_the_councils_own_change`.
- **Membership, threshold and delay** change only through the council's own process
  (`setMembers`, `setDelay` are callable only by the council contract). A change of
  membership or threshold voids every pending proposal (epoch).
- The registry, compliance module and token each fix their council at deployment
  (`immutable`) and refuse any address whose code hash is not this repository's
  `Council` runtime code (`CouncilTooWeak`): `Council` has no immutables, so the hash is
  fixed for one source and compiler setting, and its own constructor enforces 2 <= M < N
  and a delay >= 1 day. A contract that
  merely reports a threshold and a delay is refused
  (`test_a_weak_council_is_refused_at_deployment`). There is no owner, no admin role to transfer, and no
  role that administers another role: only the council grants or revokes roles.

### Deploying against a council: the recorded code hash

The runtime code includes the compiler's metadata hash, so any edit of `Council.sol` (a
comment included) or of `contracts/foundry.toml`'s compiler settings (solc 0.8.30,
`prague`, optimizer 200 runs) changes the hash, and contracts built from that tree refuse
a council deployed from an older one. `test_the_council_runtime_hash_is_the_recorded_one`
(CI, contracts job) pins the hash, so such a change cannot land unnoticed.

- Deploy the council and every governed contract from the same commit and settings.
- A later governed contract (M2's pool) is built from a commit whose test passes with the
  deployed council's hash; check it before deploying with
  `cast codehash <council>` against the recorded value.
- Changing `Council.sol` or the settings means a new council (and new governed contracts):
  update the recorded hash in the same change and say so in docs/DECISIONS.md.

So no single key can move a holder's tokens: the two functions that move tokens without
the holder's signature, `forcedTransfer` and `recoverWallet`, are council-only, and the
council needs M >= 2 distinct members and the delay. Proven by
`test_no_single_key_moves_a_holders_tokens`, `test_a_single_member_cannot_reach_the_threshold`,
`test_unauthorised_forced_transfer_refused`, `test_unauthorised_recover_wallet_refused`.

## Who may do what

| Action | Contract | Who | Takes effect | Test of the refusal |
|---|---|---|---|---|
| Grant / revoke a role | all three | council | after the delay | `test_unauthorised_grant_role_refused`, `test_unauthorised_revoke_role_refused` |
| Renounce one's own role | all three | the role holder | at once | `test_renounce_role_touches_only_the_callers_own_role` |
| Register a wallet (claims only) | registry | `REGISTRAR_ROLE` | at once | `test_unauthorised_register_refused` |
| Update KYC expiry / country | registry | `REGISTRAR_ROLE` | at once | `test_unauthorised_update_kyc_refused`, `test_unauthorised_update_country_refused` |
| Remove a wallet | registry | `REGISTRAR_ROLE` | at once | `test_unauthorised_remove_refused` |
| Bind a wallet to an investor id (a further wallet of an investor, or a correction) | registry | council | after the delay | `test_unauthorised_set_investor_id_refused` |
| Freeze a wallet | registry | `AGENT_ROLE` or council | at once | `test_unauthorised_freeze_refused` |
| Unfreeze a wallet | registry | council | after the delay | `test_unauthorised_unfreeze_refused` |
| Allowed countries, max holders, minimum holding, lock-up end | compliance | council | after the delay | `test_unauthorised_set_*_refused` (four) |
| Mint, batch mint (to eligible receivers only) | token | `MINTER_ROLE` (the M2 pool contract) | at once | `test_unauthorised_mint_refused`, `test_unauthorised_batch_mint_refused` |
| Pause | token | `AGENT_ROLE` or council | at once | `test_unauthorised_pause_refused` |
| Unpause | token | council | after the delay | `test_unauthorised_unpause_refused` |
| Raise a wallet's frozen amount | token | `AGENT_ROLE` or council | at once | `test_unauthorised_freeze_tokens_refused` |
| Lower a wallet's frozen amount | token | council | after the delay | `test_unauthorised_unfreeze_tokens_refused` |
| Forced transfer | token | council | after the delay | `test_unauthorised_forced_transfer_refused` |
| Recover a lost wallet to the same investor | token | council | after the delay | `test_unauthorised_recover_wallet_refused` |
| Propose / approve / execute | council | members | — | `test_unauthorised_propose_refused`, `..._approve_...`, `..._execute_...` |
| Revoke one's approval (before queueing) / cancel (before execution) | council | members | at once | `test_unauthorised_revoke_approval_refused`, `test_unauthorised_cancel_refused` |
| Change members, threshold, delay | council | the council itself | after the delay | `test_unauthorised_set_members_refused`, `test_unauthorised_set_delay_refused` |
| Upgrade | — | nobody | — | there is no proxy and no upgrade path (below) |

The single-key roles can only protect or act within the rules: an agent can freeze a
wallet, freeze tokens or pause at once (a compromised agent can halt transfers, never
move tokens; releasing any of it takes the council); a registrar can only write claims,
and a removed or expired claim stops a wallet sending and receiving; a minter can mint
only to an eligible receiver within the holder and minimum rules. Freezing survives
removal and re-registration (`test_freeze_survives_removal_and_re_registration`), so a
registrar cannot unfreeze by re-registering. A wallet's investor id is written once: a
registrar re-registering a removed wallet must give the same id, and only the council
rebinds it (`test_a_wallets_investor_id_is_fixed_once_set`). A registrar registers one
wallet per investor id (`InvestorIdTaken`, also after the wallet is removed: its id stays
bound); a further wallet of the same investor is bound by the council (`setInvestorId`)
before the registrar registers it, and `walletCount(id)` counts the wallets carrying it
(`test_a_registrar_cannot_register_a_second_wallet_under_an_existing_id`,
`test_a_council_binding_takes_the_id`, `test_rebinding_a_wallet_away_frees_its_old_id`,
`invariant_wallet_counts_are_exact`). `recoverWallet(lost,
replacement, investorId)` names the investor id in the proposal, and both wallets must
carry it when it executes (`test_recover_is_bound_to_the_proposed_investor_id`).

Every change of a frozen amount emits ERC-7943 `Frozen` and, with it,
`FrozenTokensChanged(account, amount, by)` naming who acted. A council move spends the
unfrozen part first and releases only the rest of the amount moved; a recovery carries
the released part to the new wallet and leaves any excess frozen on the lost one.

The minimum holding is at least one whole token, `10 ** decimals` base units
(`BadMinHolding`; the token refuses a compliance module of other decimals,
`BadDecimals`). A wallet takes a holder slot only with a balance of at least the
minimum, so filling `F` free slots costs at least `F x minHolding` (at least `F` whole
tokens), each part held by a separately registered investor's wallet: a registrar cannot
make one investor several holders. How much a whole token is worth is the pool's
economics, set by the council with `setMinHolding`
(`test_minimum_holding_is_at_least_one_whole_token`, `test_minimum_holding_is_never_zero`,
`testFuzz_filling_the_free_holder_slots_costs_free_times_the_minimum`,
`test_dust_cannot_take_a_holder_slot`).

## Holder paths (no privilege)

`transfer`, `transferFrom` (the ERC-20 allowance is the only operator path),
`approve`, and `batchTransfer` (at most 100 legs, all or nothing). There are no hooks or
callbacks (no ERC-777 / ERC-1363 receiver calls), no burn and no permit in M1.

## Every balance change passes the rules

All seven balance-changing paths (`transfer`, `transferFrom`, `batchTransfer`, `mint`,
`batchMint`, `forcedTransfer`, `recoverWallet`) go through the token's single `_update`
hook, which asks `ComplianceModule.transferRefusal` and reverts with the named
`Refusal` unless the receiver is registered, KYC-unexpired, unfrozen, from an allowed
country, within the maximum holders and at or above the minimum holding. The sender's
rules (the same four claims, lock-up, minimum left behind, unfrozen balance, pause)
apply to every path except the two council moves: a forced move exists precisely to move
tokens out of a frozen or expired wallet, but it never skips the receiver's rules. The
`EligibilityTest` matrix and the invariant `destinations_always_eligible` prove it.

## Upgrades

None. The contracts are not proxies and have no `selfdestruct`, `delegatecall` or
setter for their council, registry or compliance module. A fix ships as a new
deployment; moving holders to it is a council process (pause the old token, then mint on
the new one against the old balances) and is out of M1's scope.

## No personal data

The registry stores only an opaque investor id (assigned off-chain, never derived from
personal data), an ISO-3166 numeric country, an investor type, a KYC expiry and a frozen
flag. Events carry the same claims, addresses and reason-code hashes. Tests use
synthetic labels only.
