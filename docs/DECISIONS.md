# Decisions

Trade-offs and decisions, D-001 onward. Each entry says what was chosen and why; a
superseded decision is marked, never rewritten.

## D-001 — Base: the Backend Platform starter template

The repository begins as a copy of the Backend Platform's copy-and-own starter template —
the bounded HTTP layer, the three-role PostgreSQL split with its protections manifest,
the accounts kit, releases, restore drills, and the CI + evidence kit — renamed for this
product. The commit it came from is in `TEMPLATE_ORIGIN`; later template changes arrive
only as reviewed diffs. Nothing shares a package, service, login or database with the
template's repository or any sibling product.

## D-002 — Port band 63200-63299

Every port this repository binds on a shared development machine stays inside
63200–63299: the server on 63250, the development PostgreSQL on 63232, the template's
other defaults shifted into the band. `scripts/check-ports.sh` fails on a literal outside
the band, and the gate proves it can fail. Rationale: Linux's ephemeral range ends at
60999, so CI and a second checkout never collide.

## D-003 — Stack

Rust backend on Axum, SQLx and tokio (the template's stack); SvelteKit + TypeScript
(strict) for the web UI once the maintainer chooses this product's design system — no
`web/` product code before that. Solidity + Foundry only for on-chain code, in
`contracts/`. Everything else follows `docs/END_GOAL.md`.
## D-004 — Template pull to c9e944f

The template's changes since `TEMPLATE_ORIGIN` (`7fa7e17`) arrive as one reviewed diff,
renamed for this copy: the parameterized `scripts/check-ports.sh` (`PORT_BAND`, this
copy's 63200-63299 set in `scripts/check.sh`), `scripts/check-workflows.sh` (no duplicate
mapping keys in the workflows), the `tests/attacks` workspace member (the pentest
regression suite plus the proptest never-panics targets and their seed corpus),
`scripts/fuzz-smoke.sh` wired into the gate, and the `config.rs` code shape that stays
fmt- and clippy-clean at any crate-name length. Rationale: the maintainer's security and
stability rule lands in every product through the template, not as per-repo rewrites.
