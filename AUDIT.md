# Audit Report — Takes Contracts

**Scope:** `src/TakesMarket.sol`, `src/TakesFactory.sol`, and their interfaces in `src/interfaces/`. Tests and mocks were reviewed for coverage purposes but are not in scope for findings.

**Commit reviewed:** `a92cc0da92d0fb7d549c12dabc3825be5ad25f43`

**Date:** 2026-05-08

**Threat model assumed:**
- Asset is Circle USDC on Base (well-behaved ERC20).
- `yieldSource` is a vetted ERC4626 (initially Morpho on Base) chosen by the guardian.
- Guardian is a multisig.
- Stakers are EOAs and contracts that may be hostile to each other but not to the protocol.

**Summary:** Architecture and core math are sound. Time-weighted units, settlement, and pro-rata impairment scaling are correctly implemented and exercised by tests. The principal risks are around (a) trust placed in caller-supplied data and yield-source behavior, (b) lack of a per-market kill switch / rescue path, and (c) standard guardian-pattern hardening (2-step transfer, custom errors). **No critical issues found.**

## Findings at a glance

| ID   | Severity      | Title                                                                                          |
| ---- | ------------- | ---------------------------------------------------------------------------------------------- |
| H-1  | High          | `question` text is never validated against `questionHash` — on-chain text can be forged        |
| M-1  | Medium        | Permanent settlement DoS if the yield source `redeem` reverts                                  |
| M-2  | Medium        | `settle()` trusts `redeem`'s return value instead of measuring delta                           |
| M-3  | Medium        | Reentrancy into `getOrCreate` via a malicious yield source's `asset()` callback                |
| M-4  | Medium        | Single-step guardian transfer                                                                  |
| M-5  | Medium        | Time-weighted units can be flipped by a sufficiently large late stake                          |
| M-6  | Medium        | No per-market kill switch / rescue mechanism                                                   |
| L-1  | Low           | USDC donated directly to a market is permanently stuck                                         |
| L-2  | Low           | No event for `impaired` settlement state                                                       |
| L-3  | Low           | `Settled` event omits `isTie`                                                                  |
| L-4  | Low           | String error messages — gas + bytecode size                                                    |
| L-5  | Low           | `question` is non-immutable storage but never mutated                                          |
| L-6  | Low           | `getOrCreate` doesn't reject `questionHash == bytes32(0)`                                      |
| L-7  | Low           | Last-second stakes can produce a yield share that rounds to zero                               |
| L-8  | Informational | `MockYieldVault.transfer` return value unchecked (test only)                                   |

---

## High

### H-1. `question` text is never validated against `questionHash` — on-chain text can be forged

`TakesFactory.getOrCreate` accepts `(questionHash, question)` and trusts the hash blindly. The constructor stores `question` and emits `MarketCreated(... , question, ...)` without checking `keccak256(bytes(question)) == questionHash`.

```57:73:src/TakesFactory.sol
TakesMarket newMarket = new TakesMarket(
    questionHash,
    question,
    asset,
    currentYieldSource
);
market = address(newMarket);
_markets[questionHash] = market;

emit MarketCreated(
    questionHash,
    market,
    address(currentYieldSource),
    question,
    msg.sender
);
```

**Impact.** A malicious first creator can submit `questionHash = H` (the hash of the canonical wording) but `question = "<misleading text>"`. From that point on:

- `TakesMarket.question()` returns the attacker's text.
- The `MarketCreated` event records the attacker's text — any indexer that trusts this event is poisoned.
- Front-end users querying the on-chain text see the wrong wording but stake against the "real" hash.

This isn't a fund-loss bug, but it directly attacks the integrity of the question-to-market mapping that the whole product is built on. It is also a free attack — an attacker just needs to win the race for first stake on any topic.

**Recommendation.** Either:

1. Verify the hash in the factory: `require(keccak256(bytes(question)) == questionHash, "hash/text mismatch");`. Canonicalization rules (whitespace/case folding) live off-chain; the contract just enforces that whatever string is stored hashes to the claimed key. Off-chain canonicalization is still required, but on-chain integrity is restored.
2. Or drop `question` from on-chain storage entirely and rely on the off-chain mapping (cheaper, but loses event integrity unless 1 is also done).

---

## Medium

### M-1. Permanent settlement DoS if the yield source `redeem` reverts

`settle()` redeems all of the market's shares in a single call. If the yield source rejects the call permanently (paused, deprecated, lost solvency, withdrawal-blocked, etc.), `settle()` reverts forever and **all principal is stuck**.

```125:136:src/TakesMarket.sol
function settle() external nonReentrant {
    require(block.timestamp >= lockupEnd, "lockup not ended");
    require(!settled, "already settled");
    settled = true;

    uint256 sharesHeld = yieldSource.balanceOf(address(this));
    uint256 redeemed = 0;
    if (sharesHeld > 0) {
        redeemed = yieldSource.redeem(sharesHeld, address(this), address(this));
    }
    totalRedeemed = redeemed;
```

There is no fallback path that lets users recover principal that's still siloed in shares. The `impaired` branch only handles the case where `redeem` succeeds with a shortfall — not where `redeem` fails outright.

**Impact.** Funds-stuck condition with no recovery action. The README explicitly markets the property "funds are never held hostage" (in the context of pause), but this gap contradicts that.

**Recommendations** (in order of preference):

1. Wrap the redeem in `try` / `catch`. On failure, allow stakers to claim back their principal *in shares* (a `claimShares()` path) so they can interact with the impaired vault directly.
2. Add a `maxRedeem(address)` check and redeem `min(sharesHeld, maxRedeem)` to handle partial-liquidity vaults gracefully, then allow re-settlement of the remainder later.
3. At minimum, document this risk explicitly in the user-facing docs and ensure the guardian's vault selection process accounts for it.

### M-2. `settle()` trusts `redeem`'s return value instead of measuring delta

`totalRedeemed = redeemed` uses the value returned by `yieldSource.redeem(...)`. Per ERC4626 the return value is the assets transferred, but a misbehaving / fee-charging / fee-on-transfer-flavored vault could lie or charge a withdrawal fee that isn't reflected in the return value, breaking the impairment branch.

**Recommendation.** Measure the actual balance delta:

```solidity
uint256 balBefore = asset.balanceOf(address(this));
yieldSource.redeem(sharesHeld, address(this), address(this));
uint256 redeemed = asset.balanceOf(address(this)) - balBefore;
```

This also benignly absorbs any USDC donated directly to the market into the yield pool instead of stranding it (see L-1).

### M-3. Reentrancy into `getOrCreate` via a malicious yield source's `asset()` callback

`TakesMarket`'s constructor calls `_yieldSource.asset()` and `forceApprove`, both external calls. If the guardian rotates `currentYieldSource` to a malicious / buggy ERC4626 that re-enters the factory in `asset()`, the following is possible:

```57:73:src/TakesFactory.sol
TakesMarket newMarket = new TakesMarket(
    questionHash,
    question,
    asset,
    currentYieldSource
);
market = address(newMarket);
_markets[questionHash] = market;
```

Inside `new TakesMarket(...)` the factory re-enters with the same `questionHash`. Since `_markets[questionHash] == address(0)` is still true at that point, a *second* market gets deployed and its address is written to `_markets[questionHash]`. When the outer call resumes, it overwrites the mapping with the original. Result: an "orphan" market exists at a deployable address with the same hash but is unreachable through `getMarket`. Users could be tricked into staking into the orphan if its address leaks via events.

**Impact.** Low likelihood (requires malicious vault chosen by guardian), but creates a duplicated-market footgun. Not a direct theft.

**Recommendations.**

1. Reorder in `getOrCreate`: write `_markets[questionHash]` to a sentinel before the deployment, then to the real address — or use a `nonReentrant` modifier on `getOrCreate`.
2. Use deterministic CREATE2 deployment so the address is predictable and a duplicate would simply revert on collision.

### M-4. Single-step guardian transfer

`transferGuardian` immediately transfers control to the new address. A typo or misconfigured multisig signer can permanently lock guardian privileges (no fund loss possible because nothing valuable is gated by the guardian post-deploy, but the rotation/pause levers are lost).

```94:99:src/TakesFactory.sol
function transferGuardian(address newGuardian) external onlyGuardian {
    require(newGuardian != address(0), "zero");
    address prev = guardian;
    guardian = newGuardian;
    emit GuardianTransferred(prev, newGuardian);
}
```

**Recommendation.** Use OZ `Ownable2Step`-style pending/accept flow. This is consistent with how every other multisig-managed contract on Base is hardened.

### M-5. Time-weighted units can be flipped by a sufficiently large late stake

Acknowledged in `test_lateLargeStakerCannotFlipOrCaptureYield` and the README. With `MAX_STAKE = 1000 USDC` and a 30-day lockup, a single $1000 last-day stake (~1 day locked) accrues `1000 × 86400 ≈ 8.6e7` units, which beats a single $10/day-1 stake (~`10 × 30 × 86400 = 2.6e7` units). The "expensive but possible" framing is correct from the protocol's view — the attacker locks $1000 of capital to capture yield on a much smaller pool.

**Why this is still flagged.** The current protection only works probabilistically and only at low TVL. Any meaningful tournament/coordination value of "winning" a market exceeds the opportunity cost of $1000 locked for one day. As Sybil resistance lives off-chain (Farcaster identity), nothing prevents an attacker with N wallets from staking `N × $1000` late.

**Recommendations.**

- Consider a quadratic or concave time-weighting (e.g., `units = amount × sqrt(timeLocked)`) that disproportionately rewards early conviction.
- Or introduce a soft "lockup window" cutoff after which stakes count at reduced weight (e.g., last 7 days at 0.5×).
- At minimum, surface this in user-facing documentation explicitly so stakers price the risk.

### M-6. No per-market kill switch / rescue mechanism

The factory's pause only blocks new market creation. A bug discovered in `TakesMarket` after deployment cannot be neutralized — every existing market continues to accept stakes. There is no `rescue()` for an admin to pull funds back to stakers, no upgradeability, and no per-market pause.

**Impact.** Design tradeoff (immutability is a valuable property), but worth restating: any class of bug in `stake/settle/claim` is irreversible. Combined with M-1, this means an EVM-level vault failure on a chosen yield source has no admin remedy.

**Recommendations.**

- Consider adding an opt-in *emergency mode* triggered by guardian (only after `lockupEnd`) that allows users to withdraw their USDC pro-rata against on-hand balance, bypassing the yield-source roundtrip. This addresses M-1 in the same stroke.
- Or a per-market `paused` flag scoped to `stake()` only (claims/settle remain available — the "funds never held hostage" property is preserved).

---

## Low

### L-1. USDC donated directly to a market is permanently stuck

`claim`'s payouts sum to exactly `totalPrincipal + yieldPool`, where `yieldPool = max(0, redeemed - totalPrincipal)`. Any USDC sent directly to the market address (not via `stake`) never feeds into `redeemed`, so it's never paid out to anyone.

**Recommendation.** Switching `redeemed` to a balance-delta measurement (M-2) absorbs donations into the yield pool instead of stranding them.

### L-2. No event for `impaired` settlement state

Off-chain consumers parsing `Settled(side, yieldPool, winningUnits, totalRedeemed)` can infer impairment from `yieldPool == 0 && totalRedeemed < totalPrincipal`, but it's an inference. Add a dedicated `Impaired(uint256 totalRedeemed, uint256 totalPrincipal)` event or extend `Settled` with an `impaired` field.

### L-3. `Settled` event omits `isTie`

Same idea — currently inferable but not direct. Indexers must read state.

### L-4. String error messages — gas + bytecode size

Use custom errors throughout (`error LockupEnded(); error AmountOutOfBounds(uint256 min, uint256 max);` etc.). Saves bytecode and gives callers structured revert data.

### L-5. `question` is non-immutable storage but never mutated

```36:36:src/TakesMarket.sol
string public question;
```

Strings can't be `immutable` in 0.8.24, but you can store `bytes32` of `keccak256(question)` (already in `questionHash`) and emit `question` only in the constructor event. This drops a SLOAD per read and ~20K gas at deploy. Pair with H-1's hash check.

### L-6. `getOrCreate` doesn't reject `questionHash == bytes32(0)`

Not exploitable (just an unconventional key), but cheap to reject for hygiene.

### L-7. Last-second stakes can produce a yield share that rounds to zero

`stake()` uses `block.timestamp < lockupEnd`. A staker who lands their tx in the same block as `lockupEnd - 1` gets `(lockupEnd - stakedAt)` seconds of weighting, which can be as small as 1 second. This is correct math, but it means the *minimum* per-staker contribution to `winningUnits` is `MIN_STAKE * 1 = 1e6`. In `claim`, `yieldShare = myUnits * yieldPool / winningUnits` then rounds down. For a tiny `myUnits` paired with a very large `winningUnits` and small `yieldPool`, `yieldShare` can round to zero. Acceptable, but worth a NatSpec note.

---

## Informational

### L-8. `MockYieldVault.transfer` return value unchecked (test only)

Lint warning, but irrelevant outside tests. Flagging for completeness — production vault is not in this scope.

### Other notes

- **Re-entrancy posture is good.** `nonReentrant` on `stake/settle/claim`; CEI ordering in `stake` (state writes before `safeTransferFrom` / `deposit`); `settled = true` set before `redeem` in `settle`. The defense-in-depth comment in `settle` is accurate.
- **Math overflow analysis.** With `MAX_STAKE = 1000e6`, `LOCKUP = 30 days ≈ 2.6e6 s`, and `block.timestamp < 2^40`, all products in the unit-weight calculations fit comfortably in `uint256`. The `uint128(amount)` and `uint64(block.timestamp)` casts in `stake` are safe per the inline comments.
- **`forceApprove` for max approval is correct** for USDC (no need for the USDT-style zero-first dance). `IERC20` is OZ's, so `forceApprove` resets-then-approves.
- **Tie + empty market** is handled correctly: both `yesUnits` and `noUnits` are zero → tie branch → `yieldPool = 0` → `claim` is gated by `pos.amount > 0`. Verified by trace.
- **Settle is permissionless and idempotent** (good).
- **Factory's pause does not hold existing markets hostage** (good design, well-documented).
- **The `TakesHandler` invariants check solvency and the unit-identity at `lockupEnd`.** Coverage gaps worth filling: invariant that `redeemed == sum(claims)` at end of run when no impairment; invariant that `pos.amount == 0` if and only if user never staked; fuzz over `MIN_STAKE` boundary.
- **Test gaps.** No test for the `settle()` code path with zero stakers (state machine should be reachable but `claim()` rightly reverts). No test for impairment + tie combined. Both are quick to add.

---

## Suggested fix priority

| #   | Severity | Change                                                                                                              |
| --- | -------- | ------------------------------------------------------------------------------------------------------------------- |
| H-1 | High     | Verify `keccak256(bytes(question)) == questionHash` in factory before deploying market.                             |
| M-1 | Medium   | Add `claimShares()` or `try` / `catch` fallback in `settle()` so a permanently-broken vault doesn't trap principal. |
| M-2 | Medium   | Compute `redeemed` via balance delta.                                                                               |
| M-3 | Medium   | `nonReentrant` on `getOrCreate` (or set mapping sentinel before deploy).                                            |
| M-4 | Medium   | 2-step guardian transfer.                                                                                           |
| M-5 | Medium   | Reweight late stakes (concave time weighting) and/or document the attack cost explicitly.                           |
| M-6 | Medium   | Per-market emergency-withdraw mode (pairs naturally with M-1 fix).                                                  |
| L-* | Low      | Custom errors, balance-delta donation absorption, `impaired` / `isTie` in events, hygiene checks.                   |

The contracts are tight and well-commented; **H-1 and M-1 are the two I would not deploy to mainnet without addressing.** Everything else is hardening.

---

## Author response (2026-05-08)

| ID  | Status                  | Notes                                                                                                                                                                                                                                                                                                                              |
| --- | ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| H-1 | Fixed                   | `TakesFactory.getOrCreate` now requires `keccak256(bytes(question)) == questionHash`. Test: `test_hashTextMismatchReverts`.                                                                                                                                                                                                        |
| M-1 | Fixed                   | `settle()` wraps `redeem` in `try`/`catch`. On failure, sets `escrowFailed = true` and snapshots `sharesAtSettlement`. `claim()` distributes pro-rata yield-source shares so stakers recover via the vault directly. Test: `test_escrowFailure_paysOutSharesProRata`.                                                              |
| M-2 | Fixed                   | `totalRedeemed = asset.balanceOf(address(this))` after redeem — tolerates fee-on-transfer / misbehaving vaults and absorbs direct USDC donations (also fixes L-1).                                                                                                                                                                 |
| M-3 | Fixed (defense-in-depth)| `getOrCreate` is now `nonReentrant`. The exact attack the audit describes is mitigated by EVM `STATICCALL` semantics (the constructor's only call into the vault is `_yieldSource.asset()` via the view interface, and `forceApprove` goes to the well-behaved asset, not the vault), but the guard is good defense-in-depth.     |
| M-4 | Fixed                   | 2-step transfer: `transferGuardian(newGuardian)` sets `pendingGuardian`; the nominee finalizes via `acceptGuardian()`. `transferGuardian(address(0))` cancels a pending transfer. Tests: `test_transferGuardian_twoStep`, `test_acceptGuardian_onlyPending`, `test_transferGuardian_canBeCancelled`.                                |
| M-5 | Accepted                | Late-stake flipping is a fundamental property of *amount × time* weighting at low TVL. The auditor's recommended alternatives (concave weighting, late-stake discount) are valid but constitute a redesign of the core mechanic. Documented as a known property in the README; revisit if TVL warrants a v2 mechanic change.       |
| M-6 | Partially addressed     | The escrow-fail share-payout path (M-1 fix) gives stakers an exit when the yield source itself becomes the failure mode. A per-market guardian pause was deliberately not added: it would re-introduce the "funds held hostage" risk the architecture was designed to avoid. Smart-contract bugs in `stake/claim` remain immutable.|
| L-1 | Fixed                   | Absorbed by M-2 (absolute-balance accounting includes any direct USDC sent to the market). Test: `test_directDonationsAbsorbedIntoYieldPool`.                                                                                                                                                                                      |
| L-2 | Fixed                   | `Settled` event now includes `bool impaired`.                                                                                                                                                                                                                                                                                      |
| L-3 | Fixed                   | `Settled` event now includes `bool isTie` (and `bool escrowFailed`).                                                                                                                                                                                                                                                               |
| L-4 | Accepted                | Custom errors are a worthwhile gas optimization but the refactor surface is large; will revisit in a v2 cleanup pass.                                                                                                                                                                                                              |
| L-5 | Accepted                | `question` storage stays as-is for now; the gas saving doesn't justify changing the public read API. Pairs with H-1 fix to keep on-chain text trustworthy.                                                                                                                                                                         |
| L-6 | Fixed                   | `getOrCreate` now rejects `questionHash == bytes32(0)`. Test: `test_zeroHashRejected`.                                                                                                                                                                                                                                             |
| L-7 | Accepted                | Acknowledged in NatSpec; rounding-to-zero on tiny last-second stakes is correct integer math behavior.                                                                                                                                                                                                                             |
| L-8 | Accepted                | Test-only mock; not in production scope.                                                                                                                                                                                                                                                                                           |

**Test status:** 39/39 passing (29 unit tests + 5 invariants × 64 sequences × 32 calls).
**Slither status:** 0 medium/high findings; 3 low/informational accepted (reentrancy-benign, timestamp, naming-convention) with rationales documented inline.

---

## Post-audit mechanic change (2026-05-10): loser principal slash

Added `LOSER_PENALTY_BPS = 1000` (10%). At settlement in the healthy
non-tie path, 10% of losing-side principal is moved into `yieldPool`
and distributed to winners by time-weighted units. `claim()` deducts
the same 10% from a loser's principal payout. Skipped on tie /
impaired / escrowFailed (those modes either have no loser or already
penalize losers via principal scaling).

**Why:** the original "losers get principal back, winners only get
yield" design left the cost of being wrong at near-zero (cents of
opportunity cost on the yield), which undercut the product's
"skin in the game" thesis. The slash gives losing wrong an actual
price tag without making the contract custodial in any new way —
the slashed amount is paid out to winners in the same `claim()` call,
not held anywhere new.

**Solvency invariant still holds.** Slash is an internal redistribution
between losing-side and winning-side claimants; total payouts ≤ total
deposits + yield. Verified by tests + the existing solvency invariant.

**Test status post-change:** 45/45 passing. Slither: no new findings.

---

## Post-audit mechanic change (2026-05-16): single-tx create-and-stake

Added a factory-level orchestrator so the worst-case staker UX collapses
from 3 wallet popups (approve → getOrCreate → stake) to 2 first-time-ever
(approve factory + stake), and 1 popup forever after (stake) — across any
market. Allowance is now scoped to the factory, not per-market.

### Surface

**TakesMarket** (additive — no audited paths changed):
- `_stake(staker, from, side, amount)` private — extracted body of the
  audited `stake`. Identical accounting; `staker` is the position
  attribution, `from` is the funds source.
- `stake(side, amount)` external — unchanged signature and behavior;
  now a thin wrapper for `_stake(msg.sender, msg.sender, ...)`.
- `stakeFor(address staker, Side side, uint256 amount)` external
  nonReentrant — new public entry. Anyone can call. USDC pulled from
  msg.sender; position attributed to `staker`.

**TakesFactory** (additive):
- `_getOrCreate(hash, question)` private — extracted body of the audited
  `getOrCreate`. Identical CREATE2 + paused/hash-text checks.
- `getOrCreate(hash, question)` external — unchanged signature and
  behavior; thin wrapper.
- `stake(hash, question, side, amount)` external nonReentrant — new
  orchestrator. `_getOrCreate` → `safeTransferFrom(msg.sender, factory,
  amount)` → `forceApprove(market, amount)` → `market.stakeFor(msg.sender,
  side, amount)`.

### Why

Wallet UX: Farcaster's native (Coinbase Smart Wallet) doesn't reliably
batch via EIP-5792, and MetaMask attempts an EIP-7702 SetCode upgrade
whose simulator can't accurately price testnet gas — both surfaced as
"Insufficient funds" / "Network fee unavailable" warnings even at 0.002
ETH. Routing through a factory facade sidesteps batching entirely while
yielding strictly better UX: a one-time approve to a fixed address means
*subsequent* stakes are a single tx, ever, on any market.

### Griefing analysis for `stakeFor`

Anyone can call `Market.stakeFor(victim, side, amount)` and pay USDC out
of their own pocket to give `victim` a position on a side `victim`
didn't pick. Cost-of-attack: ≥$1 (MIN_STAKE). Damage: victim is locked
out of staking on this market themselves (single-position-per-address
invariant from V0 still holds) and can lose up to 10% of the planted
$1 at settlement if the attributed side loses. The griefer's USDC is
fully consumed; the victim can claim the remaining principal back. Net
~$0.10 of damage per $1 of griefer capital — uneconomical except as
pure spite. Acceptable for V0.

If the griefing surface ever needs to be closed: gate `stakeFor` to
`onlyFactory`. That kills general gas-sponsorship integrations but
makes the factory the only attribution route.

### Solvency invariant

Unchanged. The factory holds caller USDC for one call-frame between
transferFrom and the market's stakeFor; USDC has no transfer hooks so
reentrancy is not a concern. Allowance to the market is the exact
`amount` (force-approved, then fully consumed by the stake — verified
by `test_factoryStake_allowanceIsConsumedOnlyByAmount`). Factory holds
no lingering allowance after the call returns.

### `predictMarket` status

Retained but now vestigial. It existed to support pre-approval to the
CREATE2-predicted market in the same EIP-5792 batch as `getOrCreate`;
the single-tx orchestrator no longer needs it. Kept as a cheap view
for off-chain indexers/preflight tooling.

**Test status post-change:** 55/55 passing. Slither: no new findings
expected (additive surface; rerun before mainnet).
