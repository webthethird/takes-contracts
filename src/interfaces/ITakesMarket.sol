// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITakesMarket
/// @notice One market = one YES/NO question. Stakers commit USDC to a side
///         during a fixed lockup window; at the end, time-weighted standing
///         decides the winner, and yield accrued during the lockup is split
///         among the winning side proportional to time-weighted units.
interface ITakesMarket {
    enum Side {
        YES,
        NO
    }

    enum ClaimType {
        PREDICTIVE,
        EVALUATIVE,
        PRESCRIPTIVE,
        DESCRIPTIVE
    }

    struct Position {
        uint128 amount;       // USDC staked (6 decimals)
        uint64 stakedAt;      // block.timestamp at stake
        Side side;
        bool claimed;         // Idempotency: each address claims at most once
    }

    /* ───────────────────────── Events ───────────────────────── */

    event Staked(address indexed staker, Side side, uint256 amount, uint256 stakedAt);
    event Settled(Side winningSide, uint256 yieldPool, uint256 winningUnits);
    event Claimed(address indexed staker, uint256 principal, uint256 yieldShare);

    /* ─────────────────────── User actions ───────────────────── */

    /// @notice Stake USDC on a side. Caller must have approved USDC to this
    ///         contract for at least `amount`. Reverts after the lockup window
    ///         ends or if `amount` is outside the configured bounds.
    function stake(Side side, uint256 amount) external;

    /// @notice Permissionless. Triggers settlement once `block.timestamp >=
    ///         lockupEnd()`. Withdraws all USDC + yield from the underlying
    ///         vault, snapshots the winning side and yield pool. Idempotent.
    function settle() external;

    /// @notice Pull-based payout for the caller's position. Only callable
    ///         after settlement. Pays principal in all cases; pays a share of
    ///         the yield pool only if caller is on the winning side.
    function claim() external;

    /* ──────────────────────── Views ─────────────────────────── */

    function questionHash() external view returns (bytes32);
    function question() external view returns (string memory);
    function claimType() external view returns (ClaimType);
    function lockupEnd() external view returns (uint256);
    function settled() external view returns (bool);

    /// @notice Time-weighted units for a side AS OF time `t`. Returns 0 if
    ///         t precedes any stakes on that side.
    ///         Formula: total_units(side, t) = t × totalStaked(side)
    ///                                       − weightedTimeSum(side)
    /// @dev    For live UI display before settlement; for settlement, the
    ///         contract uses the formula at lockupEnd internally.
    function totalUnitsAt(Side side, uint256 t) external view returns (uint256);

    function totalStaked(Side side) external view returns (uint256);
    function position(address staker) external view returns (Position memory);

    /// @notice Set after settle(). Equals max(totalUnits(YES), totalUnits(NO)).
    function winningSide() external view returns (Side);
    function winningUnits() external view returns (uint256);
    function yieldPool() external view returns (uint256);
}
