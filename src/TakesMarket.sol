// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "openzeppelin-contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

import { ITakesMarket } from "./interfaces/ITakesMarket.sol";

/// @title TakesMarket
/// @notice One YES/NO market with shared 30-day lockup. Time-weighted
///         standing decides the winning side; yield from an ERC4626 vault
///         is distributed to winners proportional to their units.
contract TakesMarket is ITakesMarket, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ────────────────────────── Constants ──────────────────────────── */

    /// @notice Lockup duration. Markets are not parameterized — global constant.
    uint256 public constant LOCKUP_DURATION = 30 days;
    /// @notice $1 USDC (USDC has 6 decimals)
    uint256 public constant MIN_STAKE = 1e6;
    /// @notice $1000 USDC
    uint256 public constant MAX_STAKE = 1000e6;
    /// @notice Fraction of losing-side principal forfeited to the winning
    ///         side at settlement, in basis points (1 bp = 0.01%). 500 = 5%.
    ///         Skipped when isTie, impaired, or escrowFailed — losers
    ///         already lost or there's no winner to pay.
    uint256 public constant LOSER_PENALTY_BPS = 500;
    uint256 private constant BPS_DENOM = 10_000;

    /* ──────────────────────── Immutable state ──────────────────────── */

    bytes32 public immutable questionHash;
    IERC20 public immutable asset;
    IERC4626 public immutable yieldSource;
    uint256 public immutable lockupEnd;

    /* ──────────────────────── Mutable state ────────────────────────── */

    string public question;

    // Per-side aggregates
    uint256 public yesStaked;            // sum of YES amounts (USDC)
    uint256 public noStaked;             // sum of NO amounts
    uint256 public yesWeightedTimeSum;   // Σ amount × stakedAt for YES
    uint256 public noWeightedTimeSum;    // Σ amount × stakedAt for NO

    // Positions: one per address per market (no second stake, no flipping in V0)
    mapping(address => Position) private _positions;

    // Settlement state (set once in settle())
    bool public settled;
    bool public isTie;
    Side public winningSide;
    uint256 public winningUnits;
    uint256 public yieldPool;
    /// @notice Total USDC redeemed from the yield source at settlement.
    ///         Used to compute pro-rata principal payout if `impaired`.
    uint256 public totalRedeemed;
    /// @notice True if redeem returned less than total principal. Implies
    ///         per-staker principal loss; yieldPool is 0 in this case.
    bool public impaired;
    /// @notice True if the yield source's redeem call reverted at settlement.
    ///         Claims pay out pro-rata ERC4626 shares of `yieldSource` rather
    ///         than USDC; staker recovers via the vault directly.
    bool public escrowFailed;
    /// @notice Snapshot of `yieldSource.balanceOf(address(this))` at the
    ///         moment redeem failed. Used as the denominator for share
    ///         payouts; reading the live balance would shrink with each claim
    ///         and starve later claimers.
    uint256 public sharesAtSettlement;
    /// @notice Total USDC slashed from losing-side principal at settlement
    ///         and added to `yieldPool`. Zero on tie / impaired / escrowFailed.
    uint256 public slashedFromLosers;

    /* ──────────────────────── Construction ─────────────────────────── */

    constructor(
        bytes32 _questionHash,
        string memory _question,
        IERC20 _asset,
        IERC4626 _yieldSource
    ) {
        require(_yieldSource.asset() == address(_asset), "asset mismatch");
        questionHash = _questionHash;
        question = _question;
        asset = _asset;
        yieldSource = _yieldSource;
        lockupEnd = block.timestamp + LOCKUP_DURATION;

        // One-time max approval. The yield source pulls USDC from this market
        // when we call deposit(); pre-approving avoids a per-stake approve.
        _asset_safeApproveMax(_asset, address(_yieldSource));
    }

    /* ──────────────────────── User actions ─────────────────────────── */

    /// @inheritdoc ITakesMarket
    function stake(Side side, uint256 amount) external nonReentrant {
        require(block.timestamp < lockupEnd, "lockup ended");
        require(amount >= MIN_STAKE && amount <= MAX_STAKE, "amount out of bounds");

        Position storage pos = _positions[msg.sender];
        require(pos.amount == 0, "already staked");

        // Update side aggregates BEFORE external calls (CEI).
        if (side == Side.YES) {
            yesStaked += amount;
            yesWeightedTimeSum += amount * block.timestamp;
        } else {
            noStaked += amount;
            noWeightedTimeSum += amount * block.timestamp;
        }
        _positions[msg.sender] = Position({
            // Safe: amount is bounded by MAX_STAKE = 1000e6, far below 2^128
            // forge-lint: disable-next-line(unsafe-typecast)
            amount: uint128(amount),
            // Safe: block.timestamp fits uint64 until year 584554
            // forge-lint: disable-next-line(unsafe-typecast)
            stakedAt: uint64(block.timestamp),
            side: side,
            claimed: false
        });

        // Pull USDC from the staker. They must have approved this market.
        asset.safeTransferFrom(msg.sender, address(this), amount);
        // Supply to the yield source. Shares accrue to this market.
        // Per-stake share count is intentionally ignored — settle() reads
        // total shares via yieldSource.balanceOf(address(this)).
        // slither-disable-next-line unused-return
        yieldSource.deposit(amount, address(this));

        emit Staked(msg.sender, side, amount, block.timestamp);
    }

    /// @inheritdoc ITakesMarket
    /// @dev `nonReentrant` blocks any re-entry into stake/settle/claim, so
    ///      the state writes after the redeem() external call are safe even
    ///      against a malicious yield source. `settled` is set to true
    ///      before the external call as a defense-in-depth.
    ///
    ///      Three settlement modes:
    ///        - healthy: redeem returns >= principal -> yield pool > 0
    ///        - impaired: redeem returns < principal -> pro-rata principal loss
    ///        - escrowFailed: redeem reverts -> pro-rata share payout in claim
    function settle() external nonReentrant {
        require(block.timestamp >= lockupEnd, "lockup not ended");
        require(!settled, "already settled");
        settled = true;

        uint256 sharesHeld = yieldSource.balanceOf(address(this));
        if (sharesHeld > 0) {
            // try/catch: if the yield source rejects the redeem (paused,
            // deprecated, illiquid, etc.), fall back to share-distribution
            // mode rather than trapping principal forever. The redeem
            // return value is intentionally ignored — we read the actual
            // balance instead (M-2 in audit) so vault fees / lying vaults
            // can't lead us to overpay.
            // slither-disable-next-line unused-return
            try yieldSource.redeem(sharesHeld, address(this), address(this)) returns (uint256) {
                totalRedeemed = asset.balanceOf(address(this));
            } catch {
                escrowFailed = true;
                sharesAtSettlement = sharesHeld;
            }
        }

        uint256 totalPrincipal = yesStaked + noStaked;

        // Compute time-weighted units AT lockupEnd (frozen).
        // total_units(side, t) = t × totalStaked(side) − weightedTimeSum(side)
        uint256 yesUnits;
        uint256 noUnits;
        unchecked {
            // Always non-negative: weightedTimeSum is sum of (amount × stakedAt)
            // and stakedAt < lockupEnd by stake()'s guard.
            yesUnits = lockupEnd * yesStaked - yesWeightedTimeSum;
            noUnits = lockupEnd * noStaked - noWeightedTimeSum;
        }

        if (yesUnits > noUnits) {
            winningSide = Side.YES;
            winningUnits = yesUnits;
        } else if (noUnits > yesUnits) {
            winningSide = Side.NO;
            winningUnits = noUnits;
        } else {
            // Tie (includes the empty-market case where both are 0).
            // Yield distributes pro-rata across ALL stakers — equivalent to
            // 50/50 split between sides. winningUnits = total units.
            isTie = true;
            unchecked { winningUnits = yesUnits + noUnits; }
        }

        // Determine yield pool / impairment. Skipped on escrow-failure path
        // (no USDC moved; payouts are in shares).
        if (!escrowFailed) {
            if (totalRedeemed >= totalPrincipal) {
                unchecked { yieldPool = totalRedeemed - totalPrincipal; }
            } else {
                impaired = true;
                yieldPool = 0;
            }
        }

        // Slash losing-side principal into the yield pool. Only applies when
        // there's a clear winner and the system is healthy — if impaired or
        // escrowFailed, the losing side already lost via principal scaling
        // or has to recover via the vault directly.
        if (!isTie && !impaired && !escrowFailed) {
            uint256 loserStaked = winningSide == Side.YES ? noStaked : yesStaked;
            uint256 slash = (loserStaked * LOSER_PENALTY_BPS) / BPS_DENOM;
            slashedFromLosers = slash;
            yieldPool += slash;
        }

        emit Settled(
            winningSide,
            yieldPool,
            winningUnits,
            totalRedeemed,
            isTie,
            impaired,
            escrowFailed,
            slashedFromLosers
        );
    }

    /// @inheritdoc ITakesMarket
    function claim() external nonReentrant {
        require(settled, "not settled");
        Position storage pos = _positions[msg.sender];
        require(pos.amount > 0, "no position");
        require(!pos.claimed, "already claimed");
        pos.claimed = true;

        uint256 totalPrincipal = yesStaked + noStaked;

        // Escrow-failure path: vault redeem reverted at settlement. Distribute
        // pro-rata yield-source shares to the staker; they redeem on their
        // own. No yield branch — there is no realized yield in this mode.
        if (escrowFailed) {
            // totalPrincipal > 0 because pos.amount > 0
            uint256 sharesShare =
                (uint256(pos.amount) * sharesAtSettlement) / totalPrincipal;
            if (sharesShare > 0) {
                IERC20(address(yieldSource)).safeTransfer(msg.sender, sharesShare);
            }
            emit Claimed(msg.sender, sharesShare, 0);
            return;
        }

        uint256 principal = uint256(pos.amount);

        // Pro-rata principal scaling if impaired (losers and winners alike).
        if (impaired) {
            // totalPrincipal > 0 because pos.amount > 0
            principal = (principal * totalRedeemed) / totalPrincipal;
        } else if (!isTie && pos.side != winningSide) {
            // Healthy non-tie loser: forfeit LOSER_PENALTY_BPS of principal.
            // The slashed amount was added to yieldPool in settle() and is
            // distributed to winners via the time-weighted yield share below.
            principal -= (principal * LOSER_PENALTY_BPS) / BPS_DENOM;
        }

        // Yield share: only winners (or every staker if tie).
        uint256 yieldShare = 0;
        if (yieldPool > 0 && (isTie || pos.side == winningSide)) {
            // myUnits = amount × (lockupEnd − stakedAt)
            uint256 myUnits = uint256(pos.amount) * (lockupEnd - uint256(pos.stakedAt));
            // winningUnits > 0 because someone won (or all tied with positions)
            yieldShare = (myUnits * yieldPool) / winningUnits;
        }

        uint256 payout = principal + yieldShare;
        if (payout > 0) {
            asset.safeTransfer(msg.sender, payout);
        }

        emit Claimed(msg.sender, principal, yieldShare);
    }

    /* ─────────────────────────── Views ─────────────────────────────── */

    /// @inheritdoc ITakesMarket
    function totalUnitsAt(Side side, uint256 t) external view returns (uint256) {
        uint256 staked = side == Side.YES ? yesStaked : noStaked;
        uint256 wts = side == Side.YES ? yesWeightedTimeSum : noWeightedTimeSum;
        if (staked == 0) return 0;
        uint256 product = t * staked;
        // Defensive: callers can pass an arbitrary t; if t < earliest stakedAt
        // the product is less than wts. Return 0 instead of underflowing.
        if (product < wts) return 0;
        unchecked { return product - wts; }
    }

    /// @inheritdoc ITakesMarket
    function totalStaked(Side side) external view returns (uint256) {
        return side == Side.YES ? yesStaked : noStaked;
    }

    /// @inheritdoc ITakesMarket
    function position(address staker) external view returns (Position memory) {
        return _positions[staker];
    }

    /* ──────────────────────── Internal helpers ─────────────────────── */

    /// @dev Approve max once. Some tokens (notably USDT) require approve(0)
    ///      before a non-zero approve, but USDC follows standard ERC20 so
    ///      direct max-approve is fine here.
    function _asset_safeApproveMax(IERC20 token, address spender) private {
        token.forceApprove(spender, type(uint256).max);
    }
}
