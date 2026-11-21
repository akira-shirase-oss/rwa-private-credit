# RWA Private Credit — roadmap

M0 is this base setup; the later milestones come from the end goal (`docs/END_GOAL.md`,
mapped from the spec's weeks). A milestone's status cell says *Done* only with named
tests and evidence.

| M | Spec week | Deliverable | Gate | Status |
|---|---|---|---|---|
| M0 | — | Base setup from the starter template: CI, gate, port band 63200–63299, drills and evidence kit, `contracts/` shell | CI green on the empty product | **In progress — this base setup** |
| M1 | 1 | Registry, compliance, token | Cases 1 and 9 (contracts) | **In review** — `EligibilityTest` (case 1 on all seven paths), `RolesTest` (case 9), `CouncilTest`, invariant `destinations_always_eligible` (10,000 runs × depth 32); every guard proven by `scripts/prove-guards.sh`; market fills are M6 |
| M2 | 2 | CreditPool and subscription/refund | Case 4; full lifecycle test | Planned |
| M3 | 3 | Distributor, repayments, write-downs; `credit` mirror | Cases 2, 3, 5 (on-chain) and 6 | Planned |
| M4 | 4 | API, schema, sync, issuer portal, tape import, IPFS | Cases 7, 8 and 9 (routes); L2 and L3 | Planned |
| M5 | 5 | Investor portal: onboarding, invest, claim, dashboard | Case 12; end-to-end with 3 investor wallets | Planned |
| M6 | 6 | Secondary market, attestations, Typst reports | Cases 5 (attested), 10 and 11 | Planned |
| M7 | 7–8 | Demo binary, L1 full run, review, docs, UI audit, deploy, video | Ship gate | Planned |

## Tracked from the M1 independent review (S4)

Fixed in the M1 pass: the council's stop (`cancel`, `revokeApproval`), the council code
check, the write-once investor id and `recoverWallet`'s named id, a non-zero minimum
holding, the frozen release on council moves, `FrozenTokensChanged` naming who acted,
`canTransfer` past the balance recorded (D-005), `guards.json` uploaded by the `guards`
job, the daily run drawing and logging its fuzz seed, and GUARD markers on the token's
wiring check, both `SameWallet` checks, the proposal target and reason checks and
`grantRole`'s zero address. Still open:

| Item | Where it lands |
|---|---|
| Static analysis (Slither or equivalent), pinned, in CI | M2, before the pool contract |
| Mint has no cap and no backing in M1; supply conservation (minted = subscribed) | M2: `CreditPool` holds `MINTER_ROLE`; conservation test there |
| Holder cap counted by distinct investor id instead of wallets (if subscriptions need it) | M2 decision |
| `AGENTS.md` status line kept current with each milestone | every milestone |
