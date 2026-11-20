# src/

M1 (docs/ROADMAP.md): `IdentityRegistry` (claims and flags only), `ComplianceModule`
(the transfer rules), `PoolToken` (ERC-20 with the ERC-7943 interface; every balance
change passes one compliance hook) and `Council` (the M-of-N, timelocked process behind
every privileged action). The access-control model is docs/ACCESS_CONTROL.md. Each
protection carries a `// GUARD(name)` marker proven by scripts/prove-guards.sh. The
CreditPool and distributor land in M2 and M3.
