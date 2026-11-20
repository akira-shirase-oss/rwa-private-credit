# test/

- `Eligibility.t.sol` — END_GOAL case 1: every ineligible receiver on every path, every
  ineligible sender on every holder path, each with its named refusal and the state re-read.
- `Roles.t.sol` — case 9: every privileged entry point against every unauthorised caller.
- `Council.t.sol` — the M-of-N, delayed, once-only process.
- `Invariant.t.sol` — `destinations_always_eligible` over every path a token can move by.

`scripts/check-contracts.sh` runs them; `scripts/prove-guards.sh` proves each guard.
