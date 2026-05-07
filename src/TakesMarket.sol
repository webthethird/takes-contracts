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
        yieldSource.deposit(amount, address(this));

        emit Staked(msg.sender, side, amount, block.timestamp);
    }

    /// @inheritdoc ITakesMarket
    function settle() external nonReentrant {
        require(block.timestamp >= lockupEnd, "lockup not ended");
        require(!settled, "already settled");
        settled = true;

        // Redeem ALL of this market's yield-source shares back to USDC.
        uint256 sharesHeld = yieldSource.balanceOf(address(this));
        uint256 redeemed;
        if (sharesHeld > 0) {
            redeemed = yieldSource.redeem(sharesHeld, address(this), address(this));
        }
        totalRedeemed = redeemed;

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

        // Yield pool: redeemed > principal in the healthy case.
        if (redeemed >= totalPrincipal) {
            unchecked { yieldPool = redeemed - totalPrincipal; }
        } else {
            // Yield source impaired (lost money). All stakers share the loss
            // pro-rata; no yield to distribute.
            impaired = true;
            yieldPool = 0;
        }

        emit Settled(winningSide, yieldPool, winningUnits, redeemed);
    }

    /// @inheritdoc ITakesMarket
    function claim() external nonReentrant {
        require(settled, "not settled");
        Position storage pos = _positions[msg.sender];
        require(pos.amount > 0, "no position");
        require(!pos.claimed, "already claimed");
        pos.claimed = true;

        uint256 principal = uint256(pos.amount);

        // Pro-rata principal scaling if impaired.
        if (impaired) {
            uint256 totalPrincipal = yesStaked + noStaked;
            // totalPrincipal > 0 because pos.amount > 0
            principal = (principal * totalRedeemed) / totalPrincipal;
        }

        // Yield share: only winners (or every staker if tie).
        uint256 yieldShare;
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
