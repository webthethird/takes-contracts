# takes-contracts

Solidity contracts for [Takes](https://github.com/webthethird/takes-miniapp) — a Farcaster opinion-market mini-app where casts come with USDC stakes and the time-weighted popular side wins at lockup.

## Status

V0 scaffolding. Interfaces defined; implementations and tests in progress. Not deployed.

## Setup

```sh
forge install OpenZeppelin/openzeppelin-contracts --no-git
forge build
forge test
```

(`lib/` is gitignored; reinstall deps fresh after cloning.)

## Mechanism

- A market is created the first time a cast on a topic is staked. Identity is `keccak256(canonicalized question text)` so identical questions converge to the same market.
- Each market has a fixed **30-day lockup** from creation. New stakes accepted throughout. No early withdrawals.
- All staked USDC goes to a configurable **ERC4626 yield source** (initially a Morpho vault on Base) and earns yield for the duration of the lockup.
- At settlement: **time-weighted standing** decides the winning side. Each position contributes `units = amount × seconds_locked`. The side with greater total units wins.
- Yield distribution: winning-side stakers split the yield pool proportionally to their units. Losing-side stakers get principal back, no yield.
- Stake bounds: $1 minimum, $1000 maximum per address per market.

## Layout

```
src/
├── interfaces/
│   ├── ITakesFactory.sol
│   ├── ITakesMarket.sol
│   └── ITakesVault.sol
├── TakesFactory.sol     (TODO)
├── TakesMarket.sol      (TODO)
└── TakesVault.sol       (TODO)
test/                    (TODO)
script/                  (TODO)
```

## Deployment targets

- Base Sepolia (testnet) — for development
- Base mainnet (chain ID 8453) — for production

USDC on Base: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
