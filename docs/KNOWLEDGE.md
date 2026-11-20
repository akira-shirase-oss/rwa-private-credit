# 03 · RWA Private Credit — verified knowledge

Checked on 2026-11-20. Each fact carries its source. **UNVERIFIED** marks what this pass could not
confirm. "The spec says" marks the spec's numbers. Pin every version at M0.

## 1. ERC-3643 (permissioned security tokens)

- **Status: Final**, created 2021-07-09 ([EIP-3643](https://eips.ethereum.org/EIPS/eip-3643)). Parts: an
  ERC-20-compatible token; an Identity Registry that links each wallet to an identity contract and an
  ISO-3166 country, with `isVerified()`; Identity Registry Storage, which several registries can share; a
  Trusted Issuers Registry; a Claim Topics Registry; and Modular Compliance with `canTransfer()`. Agents
  (ERC-173 owner-appointed) get `forcedTransfer`, `setAddressFrozen`,
  `freezePartialTokens`/`unfreezePartialTokens` and `recoveryAddress`. `forcedTransfer` skips compliance
  but still requires a verified receiver. Identity is ONCHAINID.
- **The reference implementation has changed hands. The spec assumes otherwise.**
  - `TokenySolutions/T-REX` was **archived on 2025-10-28** and marked deprecated
    ([repo](https://github.com/TokenySolutions/T-REX)). Its last release, 4.1.6, says it "added commercial
    licensing to all modules of compliance as they are part of Tokeny's IP"
    ([release](https://github.com/TokenySolutions/T-REX/releases/tag/4.1.6)).
  - Development moved to `ERC-3643/ERC-3643`. It is GPL-3.0, built with Hardhat, and its latest release is
    4.1.3 (2025-06-12), with 4.2.0-beta1 as a pre-release ([repo](https://github.com/ERC-3643/ERC-3643),
    [releases](https://github.com/ERC-3643/ERC-3643/releases)). Its only listed audit is Hacken's report on
    T-REX v4.
  - ONCHAINID (`onchain-id/solidity`) is GPL-3.0. Its newest tag is 2.2.2-beta3, a 2025-07-21 pre-release
    (GitHub API). A reported "ONCHAINID v3", rebuilt as an ERC-7579 account and audited by OpenZeppelin,
    was announced in 2026 ([Crypto Briefing, 2026-10-01](https://cryptobriefing.com/openzeppelin-t-rex-regulated-token-eligibility/)).
    Its release status is **UNVERIFIED**.
  - **Consequence:** copying or importing the reference contracts makes `contracts/` GPL-3.0. Some
    compliance modules also carry a commercial-licence claim. Either conflicts with the overview's
    MIT/Apache-2.0 rule. The spec's own recommendation, "implement a simplified version yourself", is
    therefore the only licence-clean path. Write it clean-room from the ERC text.
- **ERC-7943 (uRWA, Universal RWA Interface): Final** ([EIP-7943](https://eips.ethereum.org/EIPS/eip-7943)).
  It is a minimal interface over ERC-20/721/1155: `canSend`, `canReceive`, `canTransfer`, `forcedTransfer`
  and `setFrozenTokens`/`getFrozenTokens`, named for compatibility with ERC-3643. It differs from 3643 in
  one way: its `canTransfer` must also run the per-party checks. Implementing ERC-7943 on the simplified
  token gives a standard surface without GPL code. OpenZeppelin's community contracts ship an `IERC7943`
  interface ([docs](https://docs.openzeppelin.com/community-contracts/api/interfaces)). OpenZeppelin
  Contracts is at 5.7.0 (2026-07-29, GitHub).
- **Context, not dependencies:** Chainlink's Automated Compliance Engine (ACE) launched in June 2025 with
  the ERC-3643 Association. A bond framework built with Apex Group uses CCIP for cross-chain moves
  ([Crypto Briefing](https://cryptobriefing.com/chainlink-compliance-framework-onchain-bonds-swift/)).
  "T-REX Ledger", a Polygon-CDK compliance chain, expected mainnet in Q4 2026
  ([The Block](https://www.theblock.co/news/business/2026-03-19-apex-group-taps-polygon-trex-ledger-394284)).
  Adoption figures in these sources are self-reported.

## 2. Contract-design pitfalls the spec misses

- **The compliance invariant as written cannot hold.** "No balance ever held by a non-verified address"
  fails in two ways. A holder's KYC claim can expire, or the holder can be removed, *after* they hold
  tokens. And the `SecondaryMarket` escrow, and any `Distributor` that holds tokens, are contracts. The
  enforceable invariant is:
  - every mint and transfer destination is verified at that moment;
  - contracts that hold tokens are registered as eligible holders;
  - an expired or removed holder can neither send nor receive until re-verified.

  Whether such a holder can still **claim** distributions is a policy decision (see END_GOAL Q).
- **Distribution precision.** The spec's accumulator `acc += I * 1e18 / totalSupply` loses money when USDC
  has 6 decimals and the pool token has 18. Each deposit truncates `acc` by less than one unit. Summed over
  holders, the loss is up to `totalSupply / 1e18` USDC base units. With 1,000,000 tokens (1e24 base
  units), that is up to **1 USDC lost per deposit**. Any deposit under 1 USDC rounds to an increment of
  zero and is stranded completely. Fixes:
  - scale by 1e36, or by `10^(tokenDecimals + 18)`, which stays far inside `uint256` for realistic sizes;
  - carry the truncated remainder into the next deposit;
  - or give the pool token 6 decimals.

  The fuzz property becomes "deposits − claims ≤ a documented dust bound", not "≈".
- **Every balance-changing path must settle both parties first:** mint, burn, transfer, `forcedTransfer`,
  recovery, secondary-market fill, and redemption at maturity. One missed path lets a holder claim twice
  or lose accrued interest. Frozen (partially frozen) tokens still accrue unless a rule says otherwise;
  decide and test it.
- **Mirror maths in integers.** The spec puts NAV and accruals in `rust_decimal`. Its mantissa is bounded
  by 2^96, about 7.9e28 ([docs](https://docs.rs/rust_decimal/latest/rust_decimal/struct.Decimal.html)).
  A product like `1e24 × 1e36` overflows it. The Rust mirror of on-chain accruals must use `U256`
  (`alloy-primitives`) with the contract's exact rounding. Keep `rust_decimal` for display, NAV estimates
  and schedules. "Rust and Solidity accruals agree" (spec, week 3) is then a differential test to the wei.
- **Secondary market:** escrowed listings must not earn the buyer anything retroactively. A fill must
  re-check both parties at fill time, and a buyer's maximum price guards against front-running. Use an
  atomic delivery-versus-payment swap of USDC against the token.

## 3. EIP-712 attestations

- **EIP-712: Final** ([EIP-712](https://eips.ethereum.org/EIPS/eip-712)). Domain fields: name, version,
  chainId, verifyingContract, salt. The EIP "does not include replay protection". Put a pool id, a period
  and a nonce in the struct, and bind the domain to `chainId` and `verifyingContract`.
- **Rust:** `sol!` structs implement `SolStruct::eip712_signing_hash(&Eip712Domain)` in `alloy-sol-types`
  1.7.3 ([docs.rs](https://docs.rs/alloy-sol-types/1.7.3/alloy_sol_types/trait.SolStruct.html)), within
  alloy 2.6.1 (2026-11-16, MIT OR Apache-2.0, MSRV 1.94.1; [crates.io](https://crates.io/crates/alloy)).
- **Signers that are contracts:** if the auditor or admin signer is a Safe, verify it with ERC-1271
  `isValidSignature` over `eth_call`. A Safe not yet deployed needs ERC-6492 (Final)
  ([EIP-6492](https://eips.ethereum.org/EIPS/eip-6492)). Plain `ecrecover` rejects both.
- Put the SHA-256 or keccak of the Typst report PDF in the attested struct. Then "signed report verifies"
  covers the document, not only the numbers.

## 4. Off-chain crates

| Need | Crate (version, licence, MSRV) | Note |
|---|---|---|
| Chain access, event sync | alloy 2.6.1 (MIT/Apache-2.0, 1.94.1) | Sync idempotently by (block hash, log index); handle reorgs by re-reading from a confirmed or "safe" height (a design choice, not a cited fact) |
| Decimal maths | rust_decimal 1.43.0 (MIT) | 2^96 mantissa bound, above |
| CSV loan tapes | csv 1.4.0 (Unlicense/MIT, MSRV 1.73) | Strict serde types; reject the whole file on a bad row |
| XLSX loan tapes | calamine 0.38.0 (MIT, MSRV 1.88) | Excel stores dates as serial numbers and keeps cached formula values; treat both as data to validate (general spreadsheet behaviour, **UNVERIFIED** against calamine's docs) |
| PDFs | typst 0.15.1 / typst-pdf 0.15.1 (Apache-2.0, MSRV 1.92) | Section 5 |

Versions, licences and MSRVs are from the crates.io API on 2026-11-20.

## 5. Typst for reports

- **Current: 0.15.1** (released 2026-07-17 on crates.io; 0.15.0 on 2026-06-15). Apache-2.0
  ([changelog 0.15.0](https://typst.app/docs/changelog/0.15.0/)). 0.15 targets several PDF standards at
  once (for example PDF/UA-1 with PDF/A-2a), removes `pdf.embed` (use `pdf.attach`), reworks `typst-kit` to
  make a `World` easier to build, and raises the MSRV to 1.92. 0.14 (2025-10-24) made tagged, accessible
  PDFs the default and added PDF/A-1b through PDF/A-4e ([changelog 0.14.0](https://typst.app/docs/changelog/0.14.0/)).
- **Embedding:** implement `typst::World` (fonts, files, packages, date), compile, then call
  `typst_pdf::pdf`. The `typst-as-lib` wrapper (0.18.0, MIT, targets typst 0.15) calls its own API "not
  really stable". It passes data through `sys.inputs`, needs manual `comemo::evict` with its world builder,
  and offers a `TimeProvider` for reproducible dates ([docs.rs](https://docs.rs/crate/typst-as-lib/0.18.0)).
- **Pitfalls:**
  - Bundle the fonts; the droplet has none.
  - Disable remote package downloads in production.
  - Fix the document date, so the same data gives the same bytes and the hash in the attestation stays
    stable.
  - Typst minor versions carry breaking changes (0.15 changed layout baselines), so pin the exact
    version and snapshot-test the PDF text.

## 6. Documents on IPFS

- Anything pinned to public IPFS is **public and, in practice, permanent**. The CID on-chain proves the
  bytes were not changed, not that they stay available. Only synthetic documents may go there. Never put
  KYC files or anything that looks like a real borrower's paper on it.
- **Pinata:** the free plan gives 1 GB, 500 files, 10 GB bandwidth and 10K requests. Picnic is $20/month
  ([pricing](https://pinata.cloud/pricing)). The free API rate limit is 60 requests/min
  ([limits](https://docs.pinata.cloud/account-management/limits.md)). **Never load-test Pinata.** Record
  it as a fake.
- **web3.storage, named by the spec, is outdated.** Its legacy upload and pinning APIs shut down on
  2024-01-09 in favour of w3up/Storacha
  ([web3.storage blog](https://blog.web3.storage/posts/the-data-layer-is-here-with-the-new-web3-storage)).
  Drop it from the spec.

## 7. Chains: Base Sepolia vs Polygon Amoy

| | Base Sepolia (84532) | Polygon Amoy (80002) |
|---|---|---|
| Circle test USDC | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` | `0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582` |
| Safe (admin multisig) | v1.4.1 L2 and v1.5.0 deployed | v1.4.1 L2 deployed; v1.5.0 not listed |
| Chainlink USDC/USD | `0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165` (heartbeat 24 h) | `0x1b8739bB4CdF0089d07097A9Ae5Bd274b29C6F16` (heartbeat 1 h) |
| Chainlink Proof of Reserve feeds | none on the testnet list | present (e.g. "USDFB Reserves") |
| Faucet | CDP: 0.1 ETH per 24 h | Polygon's own faucet reported deprecated; third-party faucets (**UNVERIFIED**) |

Sources: [Circle](https://developers.circle.com/stablecoins/usdc-contract-addresses);
`safe-global/safe-deployments` `v1.4.1/safe_l2.json` and `v1.5.0/safe_l2.json` (fetched today);
Chainlink directory data for [Base Sepolia](https://reference-data-directory.vercel.app/feeds-ethereum-testnet-sepolia-base-1.json)
and [Amoy](https://reference-data-directory.vercel.app/feeds-polygon-testnet-amoy.json);
[Base faucets](https://docs.base.org/base-chain/tools/network-faucets);
[Datawallet guide](https://www.datawallet.com/es/crypto/how-to-get-polygon-testnet-tokens) (a third
party). Either chain works. Base Sepolia keeps the portfolio on one chain with project 01.

## 8. Proof of Reserve and CCIP (stretch goals)

Chainlink Proof of Reserve feeds are run by Chainlink for specific assets (directory above). A demo cannot
obtain its own. A "PoR-style feed" here would be one we operate and sign, and must be labelled
self-reported, exactly like the issuer's repayment data. CCIP for a permissioned token needs identity and
compliance on every chain the token reaches. That puts it outside v1.

## 9. Legal and regulatory constraints on a public demo (not legal advice)

- **United States.** A staff statement of 2026-01-28 from three SEC divisions: tokenized securities
  remain securities. Tokenization creates no exemption, and third-party and synthetic models carry added
  risk ([Morrison Foerster](https://www.mofo.com/resources/insights/260129-sec-staff-statement-on-tokenized-securities-innovation),
  [Deloitte](https://dart.deloitte.com/USDART/home/news/all-news/2026/jan/sec-statement-tokenized-securities)).
  Fractional shares of a loan pool sold to investors are a securities offering.
- **European Union.** MiCA does not apply to crypto-assets that are financial instruments (Art. 2(4)(a))
  ([ESMA rulebook](https://www.esma.europa.eu/publications-and-data/interactive-single-rulebook/mica/article-2-scope)).
  Tokenized credit falls under securities law (MiFID II, the prospectus rules, the DLT Pilot Regime), not
  under MiCA. The spec's "MiCA/national rules" should say this.
- **India.** In June 2026 SEBI again warned investors against unlisted securities sold on unauthorised
  online platforms ([Business Today](https://businesstoday.in/markets/stocks/story/sebi-warns-investors-against-trading-unlisted-shares-on-unauthorised-platforms-537513-2026-06-17)).
  It has earlier barred unregistered online bond platforms from selling unlisted debt to retail investors
  ([Kotak Neo](https://www.kotakneo.com/news/market-news/sebi-warning-unregistered-bond-platforms/)).
  IFSCA's tokenization paper (February 2025) is still a consultation with no final framework, and the Asset
  Tokenisation (Regulation) Bill 2026 is an un-enacted private member's bill
  ([IFSCA paper](https://ifsca.gov.in/Document/ReportandPublication/ifsca-consultation-paper-on-regulatory-approach-towards-tokenization-of-real-world-assets03032025111644.pdf),
  [Trilegal, Sept 2026](https://trilegal.com/wp-content/uploads/2026/09/Tokenisation-in-India-explained_-What-it-means-for-securities-regulation-and-investors-CNBC-TV18.pdf)).
  Invoice discounting for MSMEs runs through RBI's TReDS platforms
  ([Outlook Money](https://www.outlookmoney.com/invest/the-risks-that-invoice-discounting-entails); the
  details are **UNVERIFIED** against RBI text).
- **Personal data.** India's DPDP Rules were notified on 2025-11-14, and most data-fiduciary duties
  apply from about May 2027 ([PIB](https://static.pib.gov.in/WriteReadData/specificdocs/documents/2025/nov/doc20251117695301.pdf)).
  GDPR applies to EU visitors. A demo that collects even "mock" KYC from real visitors processes personal
  data.
- **What the public demo may do:**
  - mock assets, synthetic borrowers and issuers, and test USDC only;
  - "DEMO — NOT AN OFFER" on every page, statement and PDF;
  - no real names, documents or identity data from visitors — mock KYC means choosing a synthetic
    persona, not uploading a passport;
  - no yield marketing;
  - no real-world issuer branding;
  - no path that accepts value with real-world worth.

## 10. Corrections to the spec

1. The ERC-3643 reference implementation is archived. Its successor is GPL-3.0, and some modules carry a
   commercial-licence claim. Build clean-room, and consider implementing ERC-7943 (Final).
2. The `1e18` accumulator loses up to 1 USDC per deposit at a 1M-token supply. Use 1e36 scaling or carry
   the remainder.
3. "No balance ever held by a non-verified address" is unenforceable. Restate it as a rule on destinations
   plus registered contract holders.
4. `rust_decimal` cannot mirror on-chain accumulators. Use `U256`.
5. web3.storage's legacy API no longer exists.
6. MiCA excludes financial instruments. Securities law applies.
7. Attestations need ERC-1271/6492 when the signer is a Safe, and the PDF hash belongs in the attested
   struct.
