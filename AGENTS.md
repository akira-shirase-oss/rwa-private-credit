# RWA Private Credit — agent instructions

Tokenized private credit with mock assets: every token sits with an eligible holder,
every cent of interest is accounted for to the wei, and every repayment figure says who
vouched for it.

Contract: `docs/END_GOAL.md` (what done means, scope, the required failure cases and
their drills, the ship gate); the verified facts it rests on are in
`docs/KNOWLEDGE.md`. Status: **M1 contracts in review** (registry, compliance, token,
council under `contracts/`); the off-chain services are still the renamed Backend
Platform starter template. `docs/ROADMAP.md` is the current status.

## Read first

1. `docs/END_GOAL.md` — the contract: scope, failure cases, ship gate.
2. `docs/KNOWLEDGE.md` — verified facts and sources; re-check versions at M0.
3. `docs/DECISIONS.md` — the decisions so far (base, port band, stack).
4. `docs/ROADMAP.md` — M0 onward; a status cell says *Done* only with named tests and
   evidence.

## Non-negotiables

1. **Performance and reliability come first.** Bounded queues and bodies, deadlines on
   every I/O await, idempotent writes, crash-safe state, no blocking on async workers.
2. **Evidence over claims.** Load runs are at least 1,000,000 units and run on CI-hosted
   runners, not a laptop; results carry machine, commit and load; misses are kept, never
   re-run until green.
3. **Every feature ships** regression tests + a fault-fixture path + a load scenario in
   the same change; every fixed bug gets a test that fails without it.
4. **The port band is 63200-63299.** Server 63250, development PostgreSQL 63232;
   `scripts/check-ports.sh` fails on a literal outside the band.
5. **Money is exact.** Interest and principal accounting is to the wei; no floats on any
   money path.
6. **No secrets or payloads in logs.** Typed errors (`thiserror`) in libraries, `anyhow`
   at binary boundaries; no `unwrap`/`expect` on external input.

## Verification

`scripts/check.sh` runs what CI runs — run it before every push. Local stack:
`scripts/stack.sh up` (PostgreSQL on 127.0.0.1:63232); the server binds
127.0.0.1:63250. Its credentials are public development values.

## The web UI

The design system is the maintainer's choice and has not been made. `web/` holds only a
stub: do not start a SvelteKit app until it is decided.
