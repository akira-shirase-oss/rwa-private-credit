# RWA Private Credit — end goal

**Every token sits with an eligible holder, every cent of interest is accounted for to the wei, and
every repayment figure says who vouched for it.**

A demonstration platform for tokenized private credit on an EVM testnet. A (mock) issuer creates a credit
pool from a synthetic loan tape. Eligible (mock-KYC) investors subscribe with test USDC and receive
permissioned pool tokens built on the ERC-3643 pattern. Transfers settle only between verified wallets.
As the issuer deposits repayments, holders claim interest pro rata through a pull-based distributor.
Late payments and defaults write NAV down, and recoveries flow back. A restricted secondary market lets
eligible holders trade. Repayment reports are EIP-712 attestations by the issuer and, optionally, an
auditor. Investor statements and pool reports are reproducible Typst PDFs whose hashes are attested. The
documentation says plainly what tokenization cannot do: it cannot make borrowers repay, it cannot give
holders a legal claim without an SPV or trust, and it cannot make the issuer's data honest. Nothing here
is an offer.

**Origin.** Programme spec 03, v2.0 (2026-11-20), merged with the repository rules in `AGENTS.md`.
Conflicts are open questions, not resolved here. Verified facts and corrections are in `KNOWLEDGE.md`.
Numbers are the spec's or proposed targets, never measurements.

## Users and the job to be done

- **Reviewer (TradFi, RWA or bank-innovation team):** "Show me you understand compliance-aware token
  design, cash-flow waterfalls and the off-chain boundary, and let me follow one pool's whole history from
  the dashboard alone" (spec success metric).
- **Issuer persona (demo):** create a pool, upload a tape, report repayments, mark defaults.
- **Investor persona (demo):** onboard as a synthetic persona, subscribe, claim, trade, redeem.
- **Admin and compliance agent:** approve issuers and investors, freeze, force-transfer under a recorded
  reason, read the audit log.

## v1 scope

- **Contracts**, written clean-room from the ERC text (KNOWLEDGE §1):
  - `IdentityRegistry`: wallet → country, investor type, KYC expiry, frozen;
  - `ComplianceModule`: four or five rules done well (spec) — both parties verified, not frozen, country
    allowed, maximum holders, lock-up;
  - `PoolToken`: ERC-20 with the transfer hook, pause, forced transfer, recovery, and the ERC-7943
    interface (open question Q2);
  - `CreditPool`: the state machine DRAFT → SUBSCRIPTION → ACTIVE → MATURED → CLOSED, with REFUNDING and
    IMPAIRED branches;
  - `Distributor`: accumulator scaled to 1e36 or with remainder carry;
  - `SecondaryMarket` (spec P1, in v1): atomic USDC-versus-token fill with a re-check at fill time.
- **Admin roles** held by a Safe multisig on testnet, with a timelock on parameter changes.
- **Off-chain:**
  - an Axum API with role-based routes for investor, issuer and admin;
  - an alloy event-sync worker into Postgres, with a reconciliation check against the chain;
  - a pure `credit` crate for schedules, accruals, NAV and write-downs, which mirrors on-chain maths in
    `U256`;
  - a loan-tape import from CSV and XLSX that refuses the whole file and reports line-level errors;
  - EIP-712 sign and verify, including ERC-1271 for Safe signers;
  - Typst monthly pool reports and investor statements;
  - synthetic documents pinned to IPFS.
- **The SvelteKit portals** `/invest`, `/issuer` and `/admin`, covering every operation, with "DEMO — NOT
  AN OFFER" on every view and document.
- **A demo-scenario binary:** 2 issuers, 3 pools, 5 investors, 12 months of synthetic history with late
  payment, default and recovery (spec), and realistic delinquency and seasonality.
- **Docs:** `WHAT_TOKENIZATION_CANT_DO.md` and `COMPLIANCE.md`.

## Non-goals (v1)

Real assets, real issuers, real KYC or any personal data from visitors. Real money, mainnet, fees.
Tranching and waterfalls (spec P2). Proof-of-Reserve feeds (we cannot obtain one; a self-signed feed is
only a label) and CCIP. ONCHAINID claim issuers. Copying or forking the T-REX or ERC-3643 reference code
(licence). Legal structuring (SPV or trust). Tax treatment.

## Architecture in brief

A Rust workspace (`api`, `sync`, `credit`, `reports`, `attest`, `chain`, `db`) on Tokio, Axum and SQLx
over PostgreSQL. Solidity and Foundry for `contracts/` only. SvelteKit + TypeScript (strict) + Tailwind
v4 + shadcn-svelte, with viem/@wagmi/core for wallet actions. Per the standard layout, the Rust server
serves the API and the static portals on one origin from the product's droplet (systemd, Caddy), and the
landing and docs sites go on Cloudflare Pages. The spec's Pages split is open (Q6). A server-side alloy
signer, testnet only, performs registry updates. Its key sits in droplet secrets and it holds no
admin-multisig power. `credit` carries no I/O, and an architecture check enforces it. Postgres is a
projection of chain state plus off-chain records; the chain wins on every on-chain fact.

## Non-negotiable invariants

1. **Eligible destinations only.** Every mint and transfer destination is verified, unfrozen and allowed
   at that moment. Contracts that hold tokens are registered holders. An expired or removed holder can
   neither send nor receive.
2. **Interest is conserved.** Claimed ≤ deposited interest, always. Deposited − claimed ≤ the documented
   dust bound. Every balance-changing path settles both parties before balances move.
3. **Integer mirror.** The Rust `credit` mirror equals the Solidity result to the wei over every seeded
   scenario.
4. **Repayments are backed.** A repayment report without a matching USDC deposit is refused. Issuer data
   is labelled "self-reported" until a second signer attests it.
5. **No personal data on-chain, on IPFS or in logs.** Only claims and flags on-chain.
6. **Chain is authority.** The sync is idempotent by (block hash, log index). Reconciliation reports zero
   drift or names each difference.
7. **Privileged actions are multisig, timelocked and evented.** Every admin route and privileged function
   rejects other callers.
8. **Evidence over claims.** Results carry machine, commit and `uptime`. Misses are kept.

## Required failure cases (contract, not options)

| # | Trigger | Required result | Proven by | Pass condition | From |
|---|---|---|---|---|---|
| 1 | **Ineligible transfer**: unverified, frozen, disallowed country, expired KYC, over max holders, under minimum holding, inside lock-up; by transfer, `transferFrom`, mint and a market fill | Revert | Foundry unit tests plus invariant `destinations_always_eligible` | Zero successful moves to an ineligible address across ≥10,000 fuzz runs (proposed; spec says "100% under fuzzing") | M1 |
| 2 | **Rounding**: many holders, random transfers, deposits from 1 base unit to large, dust | Conserved | Fuzz `interest_conserved`, differential `rust_mirror_equals_solidity` | Claimed ≤ deposited; residue ≤ bound; Rust = Solidity to the wei | M3 |
| 3 | **Hidden balance paths**: mint, burn, `forcedTransfer`, recovery, fill, redemption | Accrual preserved | `every_balance_path_checkpoints` | Owed-before = owed-after for both parties on every path | M3 |
| 4 | **Subscription target missed** | Refund | Lifecycle test `refunding_path` | Each subscriber refunds exactly once; a second refund or a claim reverts | M2 |
| 5 | **False or unbacked repayment report** | Refused or labelled | `repayment_requires_deposit`, `unregistered_signer_rejected` | No distribution without USDC; an unsigned figure shows "self-reported" | M3 / M6 |
| 6 | **Default and recovery**: late, defaulted, partial recovery | NAV written down, recoveries flow | 12-month scenario test (spec); proptest on `credit` | NAV ≤ outstanding principal + accrued interest; accrued interest never negative (spec); state transitions match the machine | M3 |
| 7 | **Sync faults**: reorg, duplicate logs, RPC gap, worker killed mid-batch | Converges | Drill `sync-chaos` (Anvil reorgs, SIGKILL) | Zero duplicate rows; reconciliation reports zero drift after recovery | M4 |
| 8 | **Hostile loan tape**: malformed rows, wrong encoding, formula cells, huge sheet, XLSX bomb, ambiguous dates | Refused whole | Fixtures `hostile-tapes/`, a `cargo-fuzz` target per parser | Named refusal with row; zero rows persisted; bounded memory and time (limits set at M4) | M4 |
| 9 | **Unauthorised privileged call**, on every privileged function and admin route | Refused | Role tests (Foundry, `#[sqlx::test]`) (spec) | 100% of privileged entry points covered by a test that fails without the check | M1 / M4 |
| 10 | **Attestation attacks**: replay across chain, contract or period; wrong signer; Safe signer (ERC-1271); tampered PDF | Verify fails or succeeds correctly | `attestation_verification_matrix` | Each case gives its expected result with a reason code | M6 |
| 11 | **Market race**: buyer loses eligibility between listing and fill; price changed | Fill reverts | `fill_rechecks_eligibility`, `fill_respects_max_price` | No fill to an ineligible buyer; no fill above the buyer's maximum | M6 |
| 12 | **Personal data leak** | None | `no_pii_anywhere` scans events, CIDs, logs and PDFs for fixture PII | Zero matches | M5 |

## Ship gate

Ship when **a reviewer can follow one pool from creation through default and recovery on the live
testnet, and every number on the screen ties back to the chain or to a named signer.** All on the release
commit:

- [ ] Failure cases 1–12 pass on CI. Invariant list in the README. Slither report committed and triaged.
- [ ] Demo scenario (happy path, late payment, default, recovery) runs from a clean deploy (spec).
- [ ] Load scenarios L1–L3 committed under `perf/results/` with machine, commit and `uptime`; thresholds
      met or the miss recorded with a decision.
- [ ] Independent security review of contracts, roles and the server signer, with findings fixed or
      accepted in writing.
- [ ] Docs site `rwa-credit-docs` (Astro Starlight, Cloudflare Pages): quick start ending in a real API
      call with a token, concepts (including what tokenization cannot do), guides, an API reference from
      OpenAPI, self-hosting, and `/changelog`. Every example runs in CI.
- [ ] UI covers every operation for issuer, investor and admin. UI audit at 1440 and 390 px, light and
      dark.
- [ ] Live: contracts verified; `deployments/*.json`; admin roles on a Safe; seeded data so no screen is
      empty; laptop off; `/healthz` watched by Service Monitor; backups with a restore drill.
- [ ] Overview Definition of Done: README with a 60–90 s video, an architecture diagram, a quick start and
      limitations; CI badge (nextest, clippy, cargo-deny); coverage; p50/p99 and memory; `ARCHITECTURE.md`;
      build post and thread; clean history; MIT or Apache-2.0; `WHAT_TOKENIZATION_CANT_DO.md`.

## Load scenarios (≥1,000,000 units each)

Proposed thresholds, to be confirmed at M0. No third party (RPC, Pinata) is load-tested; they are recorded
fakes.

- **L1 · Portal and API reads:** k6, 1,000,000 requests at a fixed rate. The mix: pool pages, health
  timelines, holdings, accrued-interest previews, cached statement downloads, plus admin approvals. The
  database is seeded with 1,000 pools, 100,000 investors and 10,000,000 repayment rows. Proposed: zero 5xx;
  p99 ≤ 50 ms for reads; RSS ≤ 256 MiB; statement downloads served from content-addressed cache.
- **L2 · Event sync:** 1,000,000 recorded on-chain events replayed, with reorgs and kills injected.
  Proposed: zero duplicate or missing rows; reconciliation drift zero; throughput and p99 batch-commit
  latency recorded.
- **L3 · Loan-tape import and accrual:** 1,000,000 tape rows imported and accrued through `credit`.
  Proposed: zero rows persisted from a refused file; the accrual digest identical across two runs;
  peak RSS recorded. A separate Typst benchmark records render time per statement (no 1M target; report
  generation is not on the request path).

## Milestones (mapped from the spec's weeks)

| M | Spec week | Deliverable | Gate |
|---|---|---|---|
| M0 | before week 1 | Workspace, CI (fmt, clippy, nextest, deny, `sqlx prepare --check`, forge, Slither), architecture check, L1 skeleton at 1M, `sync-chaos` skeleton, docs skeleton | CI green; first run and drill committed |
| M1 | 1 | Registry, compliance, token | Cases 1 and 9 (contracts) |
| M2 | 2 | CreditPool and subscription/refund | Case 4; full lifecycle test (spec) |
| M3 | 3 | Distributor, repayments, write-downs; `credit` mirror | Cases 2, 3, 5 (on-chain) and 6 |
| M4 | 4 | API, schema, sync, issuer portal, tape import, IPFS | Cases 7, 8 and 9 (routes); L2 and L3 |
| M5 | 5 | Investor portal: onboarding, invest, claim, dashboard | Case 12; end-to-end with 3 investor wallets (spec) |
| M6 | 6 | Secondary market, attestations, Typst reports | Cases 5 (attested), 10 and 11 |
| M7 | 7–8 | Demo binary, L1 full run, review, docs, UI audit, deploy, video | Ship gate |

## Open questions for the maintainer

1. **Jurisdiction for the framing:** India (SEBI and RBI), the US, the EU or elsewhere? It decides the
   wording of the disclaimer and of `COMPLIANCE.md`.
2. **Token standard surface:** a simplified ERC-3643 pattern only, or also ERC-7943 (Final)? Confirm that
   no T-REX or ERC-3643 code may be copied, because of GPL-3.0 and the commercial-licence claim.
3. **Chain:** Base Sepolia (one chain with project 01) or Polygon Amoy?
4. **Public onboarding:** can any visitor pick a synthetic persona and receive tokens, or are only the
   five seeded investors usable? Real visitor data is out either way.
5. **Policies the contracts must encode:** can an expired-KYC holder still claim interest? Do frozen
   tokens accrue? What is the NAV method for write-downs, and the recovery order?
6. **Hosting:** the spec's Pages + Docker Compose + shared droplet, or the standard's same-origin
   server on its own droplet? **Database:** Neon with `verify-full` or co-located Postgres?
7. **IPFS:** pin synthetic documents on Pinata (free tier limits apply), or keep documents off IPFS and
   hash them on-chain only?
8. **Design identity** for the three portals (options with screenshots).
9. **Secondary market** in v1 (spec P1, included above) or deferred?
10. **Repository names:** `rwa-credit` and `rwa-credit-docs`, as the spec implies?
