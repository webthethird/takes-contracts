# takes-contracts

Solidity contracts for **Takes** — an on-chain opinion market that lives inside Farcaster. Cast a take, back it with USDC, and the time-weighted popular side wins at lockup. There is no oracle: the crowd settles it.

Part of a three-repo project:

- **takes-contracts** (this repo) — Foundry project: factory + per-question markets on Base
- [takes-miniapp](https://github.com/webthethird/takes-miniapp) — Farcaster mini app (Next.js) that drives the contracts
- [takes-classifier](https://github.com/webthethird/takes-classifier) — prototype that turns casts into canonical market questions

## Status

Deployed to **Base Sepolia**, never to mainnet. 64/64 tests passing (`forge test`), including a solvency invariant suite. Self-audited — see [`AUDIT.md`](./AUDIT.md) for findings and remediation.

| | |
| --- | --- |
| `TakesFactory` (Base Sepolia) | [`0x83B1AE07f092a0dbAD55cE47548F7aF5ee21B653`](https://sepolia.basescan.org/address/0x83B1AE07f092a0dbAD55cE47548F7aF5ee21B653) |
| USDC (Circle, Base Sepolia) | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| Yield source (testnet) | `MockYieldVault` at `0xd819BA5c6f86Be0771c95489c40e45535Ad7c1B0` |

**Development is paused.** The mechanism works end to end on testnet; the project stalled on distribution, not on the contracts — a time-weighted market needs both sides staked before the standing means anything, and the mini app never reached the audience to bootstrap that. The code here is complete and documented for anyone (including future me) picking it back up.

## Mechanism

**Markets are addressed by content.** A market is identified by
`marketKey = keccak256(abi.encode(questionHash, lockupDuration))`, where
`questionHash = keccak256(canonicalized question text)`. The factory
CREATE2-deploys with `marketKey` as the salt, so:

- identical questions converge on the same market instead of fragmenting into a dozen thin ones
- the address is predictable off-chain before deployment (`predictMarket`)
- the same question at a different lockup is deliberately a *different* market

Canonicalization (casing, whitespace, positive framing) happens off-chain. The
factory enforces only that the stored text actually hashes to the key
(`keccak256(bytes(question)) == questionHash`), so on-chain text can't be forged.

**Lockup.** Each market carries its own immutable `lockupDuration`, bounded by
the factory to `[1 day, 365 days]`. New stakes are accepted throughout. No early
withdrawal. The mini app defaults to 30 days.

**Yield.** All staked USDC is deposited into a configurable ERC-4626 yield source
(Morpho on Base was the intended production vault) and earns for the duration of
the lockup. A market is wired to whatever source was current at its creation;
rotating the factory's source affects only future markets.

**Settlement is time-weighted.** Every position accrues
`units = Σ amountᵢ × (lockupEnd − stakedAtᵢ)`. At `settle()`, the side with more
total units wins. Being early and staying is what pays — size alone doesn't
carry a market.

**Payouts.**

- Winners get principal back plus a pro-rata share of the yield pool, weighted by their units.
- Losers get principal back minus `LOSER_PENALTY_BPS` (currently **10%**), which is added to the yield pool for the winners.
- On a tie (including an empty market), yield distributes pro-rata across all stakers and no principal is slashed.

**Stake bounds.** $1 minimum per individual stake; $1,000 maximum *total position*
per address per market, cumulative across top-ups. Positions can be topped up
any number of times but the first stake locks the side — no flipping in V0.

### Three settlement modes

`settle()` is designed so principal is never trapped by a misbehaving yield source:

| Mode | Trigger | Behavior |
| --- | --- | --- |
| healthy | `redeem` returns ≥ principal | yield pool = surplus + loser slash; normal payouts |
| impaired | `redeem` returns < principal | `impaired = true`, no yield pool, no slash; every staker's principal scales pro-rata to `totalRedeemed` |
| escrow-failed | `redeem` reverts | `escrowFailed = true`; `claim()` distributes pro-rata ERC-4626 *shares* so stakers redeem via the vault directly |

Accounting reads `asset.balanceOf(address(this))` rather than trusting `redeem`'s
return value, which tolerates fee-charging or lying vaults and absorbs any USDC
donated directly to the market.

### Single-approval staking

`TakesFactory.stake()` is a create-and-stake entry point: it get-or-creates the
market, pulls USDC from the caller, and forwards it via `TakesMarket.stakeFor()`
so the position is attributed to the caller rather than the factory.

This exists for UX, not gas. Because the allowance is scoped to the factory — one
fixed address — a user approves **once** and then every stake on every market,
forever, is a single transaction. Without it, each new market meant a fresh
approval plus a stake: three wallet popups in the worst case, which is fatal on
mobile.

## Layout

```
src/
├── interfaces/
│   ├── ITakesFactory.sol
│   └── ITakesMarket.sol
├── TakesFactory.sol      lookup/deploy by market key, yield-source registry, guardian
└── TakesMarket.sol       one YES/NO market: stake, settle, claim
test/
├── TakesFactory.t.sol
├── TakesMarket.t.sol
├── TakesInvariant.t.sol  solvency under fuzzed stake/warp/yield/loss sequences
└── mocks/{MockUSDC,MockYieldVault}.sol
script/
└── Deploy.s.sol          chain-aware: real USDC + required YIELD_SOURCE on mainnet
```

There is no `TakesVault.sol` — the yield source is any external ERC-4626, not a
contract this project owns.

## Setup

Requires [Foundry](https://book.getfoundry.sh/) (developed on forge 1.7.1, solc 0.8.24).

```sh
forge install foundry-rs/forge-std@v1.16.1 --no-git
forge install OpenZeppelin/openzeppelin-contracts@v5.6.1 --no-git
forge build
forge test
```

`lib/` is gitignored and these aren't submodules, so dependencies must be
installed fresh after cloning. The tags above are the versions the contracts
were built and tested against — pin them rather than taking latest, since
nothing else in the repo records the dependency versions. Import paths come
from `remappings.txt`.

```sh
forge test -vvv                    # verbose
forge test --match-contract Invariant
forge coverage
```

## Deploy

Copy `.env.example` to `.env` and fill in RPC URLs, `DEPLOY_PRIVATE_KEY`,
`GUARDIAN`, and `BASESCAN_API_KEY`. Verification uses the Etherscan v2 unified
endpoint — one key covers all chains.

```sh
# Base Sepolia. If YIELD_SOURCE is unset, also deploys a MockYieldVault.
GUARDIAN=0x... forge script script/Deploy.s.sol \
    --rpc-url base_sepolia --broadcast --private-key $DEPLOY_PRIVATE_KEY

# Base mainnet. Refuses to run without a real YIELD_SOURCE.
GUARDIAN=0x... YIELD_SOURCE=0x... forge script script/Deploy.s.sol \
    --rpc-url base --broadcast --verify --private-key $DEPLOY_PRIVATE_KEY
```

After deploying, update `TAKES_FACTORY` in the mini app's `lib/contracts.ts`.

## Security

`AUDIT.md` is a full self-audit of `TakesFactory`, `TakesMarket`, and their
interfaces, with a findings table, author responses, and a changelog of every
post-audit mechanic change. No critical issues. Fixed: on-chain text forgery
(H-1), permanent settlement DoS on vault `redeem` revert (M-1), trusting
`redeem`'s return value (M-2), reentrancy via a malicious yield source's
`asset()` callback (M-3), single-step guardian transfer (M-4), stuck donations
(L-1), and missing settlement-state events (L-2/L-3/L-6).

Trust model: USDC as a well-behaved ERC-20, a guardian multisig that can pause
new-market creation and rotate the yield source for *future* markets only, and a
vetted ERC-4626 vault. The guardian cannot touch an existing market, pause
`stake`/`settle`/`claim`, or move staker funds.

Slither was run clean as of the 2026-05-07 invariant-test commit; the
single-tx-stake and per-market-lockup changes that followed have **not** been
re-scanned. Rerun before any mainnet deploy.

### Known properties, accepted by design

- **Late-stake flipping (M-5).** A large stake late in the lockup can flip the time-weighted standing at low TVL. This is intrinsic to `amount × time` weighting, and it gets *worse* at short lockups, where early and late units differ very little. Mitigations like concave weighting or a late-stake discount would be a redesign of the core mechanic, not a patch. Off-chain Sybil resistance comes from Farcaster identity plus the $1,000 per-address cap.
- **No per-market kill switch (M-6).** Deliberate. A guardian able to halt a live market would reintroduce exactly the funds-held-hostage risk the architecture avoids. The escrow-failure path covers a failing yield source; a bug in `stake`/`claim` itself is immutable.
- **String revert reasons (L-4)** and **non-immutable `question` storage (L-5)** are known gas costs, kept for readability and a stable public read API.
- **Rounding (L-7).** A tiny last-second stake can round its yield share to zero. Correct integer-math behavior.

## License

MIT
