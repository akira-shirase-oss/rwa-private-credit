# Access control (M1: registry, compliance, token)

Who may do what to the identity registry, the compliance module and the pool token, and
the process that guards every action that can move a holder's tokens. The tests that
prove each line are named; `scripts/prove-guards.sh` removes each guard in turn and
requires its tests to fail (CI job `guards`).

## The council: the only path to a holder's tokens

`Council` is an M-of-N multisig with a timelock, written for this repository:

- **Members:** 2 to 16 distinct non-zero addresses; **threshold M >= 2** and at most N.
- **Delay:** between 1 day and 30 days; a queued call is executable for a 14-day grace
  period after its delay, then expires.
- **Process:** a member proposes `target.call(data)` with a non-zero `reasonCode` (the
  hash of the off-chain case record: never personal data) and the proposal counts as
  that member's approval; other members approve; at M approvals it is queued; after the
  delay any member executes it, with exactly the proposed bytes, once.
- **Membership, threshold and delay** change only through the council's own process
  (`setMembers`, `setDelay` are callable only by the council contract). A change of
  membership or threshold voids every pending proposal (epoch).
- The registry, compliance module and token each fix their council at deployment
  (`immutable`) and refuse a council that is not a contract reporting threshold >= 2 and
  delay >= 1 day (`CouncilTooWeak`). There is no owner, no admin role to transfer, and no
  role that administers another role: only the council grants or revokes roles.

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
| Change members, threshold, delay | council | the council itself | after the delay | `test_unauthorised_set_members_refused`, `test_unauthorised_set_delay_refused` |
| Upgrade | — | nobody | — | there is no proxy and no upgrade path (below) |

The single-key roles can only protect or act within the rules: an agent can freeze a
wallet, freeze tokens or pause at once (a compromised agent can halt transfers, never
move tokens; releasing any of it takes the council); a registrar can only write claims,
and a removed or expired claim stops a wallet sending and receiving; a minter can mint
only to an eligible receiver within the holder and minimum rules. Freezing survives
removal and re-registration (`test_freeze_survives_removal_and_re_registration`), so a
registrar cannot unfreeze by re-registering.

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
