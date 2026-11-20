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

## D-004 — M1 contracts: clean-room, council-governed, no upgrades

The registry, compliance module and token are written clean-room from the ERC-3643
pattern and the ERC-7943 text (docs/KNOWLEDGE.md: the reference implementation's licence
is not compatible), on OpenZeppelin Contracts v5.7.0 (`ERC20`, `IERC165`, MIT) and
forge-std v1.17.0, both git submodules pinned by commit; Foundry v1.10.0 is installed by
`scripts/install-foundry.sh`, checked against its SHA-256. Every privileged action that
can move a holder's tokens or loosen a rule goes through `Council`, an M-of-N (M >= 2)
multisig with a delay of at least a day, written here rather than depending on an
external multisig so the whole process is tested in this repository. Protective actions
(freeze, pause) take one agent key and act at once; releasing them takes the council.
There are no proxies: an upgrade is a new deployment. The written model is
docs/ACCESS_CONTROL.md. The `credit` integer mirror is M3's (END_GOAL invariant 3): M1
has no arithmetic beyond balance and holder counts, so no mirror is built here.

