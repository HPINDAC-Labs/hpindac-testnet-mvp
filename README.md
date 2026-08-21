HPINDAC

Hedera-native infrastructure for launching index vaults.

https://hashscan.io/testnet/contract/0.0.10120855

HPINDAC is a factory contract that lets a fund manager, DAO, or institution deploy their own isolated, secure index vault on Hedera — without building custody, minting, and security logic from scratch. Users deposit a stablecoin, receive a token representing their share of a defined basket, and redeem it later for the underlying value minus a fee.

Status: Early-Stage, Testnet, Pre-Audit
✅ Core contracts written and compiled with zero errors/warnings
✅ IndexFactory deployed and Sourcify-verified on Hedera testnet
⬜ Independent security audit — not yet done
⬜ Full vault deposit/mint/redeem flow tested end-to-end — not yet done
⬜ Mainnet deployment — not planned until the above are complete
This is honest by design. Nothing here is production-ready, and no claim in this repo should be read otherwise.

Why Hedera, and Why This Architecture
Most comparable infrastructure (e.g., Reserve Protocol) is built for EVM chains and depends on cross-chain bridges — historically the largest single source of DeFi exploits. HPINDAC is built entirely on Hedera's native token service (HTS precompile, address 0x167), with no bridges at all.

A second, equally important difference: immutability. Reserve Protocol's own documentation states its contracts can be upgraded through governance. HPINDAC's core financial logic — deposit, redemption, fee split, and custody rules — is designed to be immutable once deployed: it cannot be changed afterward, by anyone, including the founders.

The only mutable component is the oracle price-feed pointer, and even that requires multisig approval plus a mandatory 24-hour timelock, never a single key.
This is a real tradeoff, not a free upgrade: immutable code can't be patched if a flaw is discovered post-launch, which is exactly why an independent security audit before any mainnet deployment is treated as non-negotiable in this project, not optional.

One honest note on decentralization: HPINDAC is not decentralized today — it's currently a two-founder team with a multisig as a security stopgap, not a governance structure. Reserve Protocol's own governance is also more concentrated than its branding suggests (independent analysis shows a single investor holds a majority of its governance token). 
Genuine decentralization is a future goal for this project, not a current claim.

Security design is built specifically against a real, recent precedent: in July 2026, Hedera's largest lending protocol lost ~$9M to an oracle price-manipulation attack. HPINDAC's vault enforces deviation limits on price updates, requires multisig + timelock approval to change its oracle source, and auto-pauses on suspected anomalies.

Known Limitations (Read Before Contributing or Reviewing)
This is a Phase 1 draft. Documented, open gaps that need real engineering attention:
Oracle single-source trust between updates — deviation limits block sudden spikes, not gradual manipulation across multiple small updates. Needs multi-source price reconciliation.
FounderSplit.sol balance query is a placeholder — _stablecoinBalance() currently returns 0.
HTS token key configuration is unresolved — needs explicit exclusion of admin/freeze/wipe keys.
Security defenses are untested, not just unaudited — no test suite yet simulating a deviation-limit or staleness-pause scenario.
Factory access control is a single key — a stopgap, not a long-term design.

Contract Structure
Code
Contributing / Getting Involved
This project is looking for a Hedera/Solidity developer to review, harden, and help take the codebase further. If the architecture or the security problem interests you, open an issue or reach out — see contact details in the repo profile.

License
Apache-2.0
