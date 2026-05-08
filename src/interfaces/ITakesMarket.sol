// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "openzeppelin-contracts/interfaces/IERC4626.sol";

/// @title ITakesMarket
/// @notice One market = one YES/NO question. Stakers commit USDC during a
///         fixed lockup window; the staked USDC is supplied to an ERC4626
///         yield source for the duration of the lockup. At settlement,
///         time-weighted standing decides the winning side, and yield is
///         distributed to winning-side stakers proportionally to their
///         time-weighted units.
///
/// @dev Each market holds its own ERC4626 shares. The market is the ERC4626
///      depositor — when stakers commit USDC, the market pulls USDC then
///      deposits to its configured yield source. At settlement the market
///      redeems all its shares.
interface ITakesMarket {
    enum Side {
        YES,
        NO
    }

    struct Position {
        uint128 amount;       // USDC staked (6 decimals)
        uint64 stakedAt;      // block.timestamp at stake
        Side side;
        bool claimed;         // Idempotency: each address claims at most once
    }

    /* ───────────────────────── Events ───────────────────────── */

    event Staked(address indexed staker, Side side, uint256 amount, uint256 stakedAt);
    event Settled(
        Side winningSide,
        uint256 yieldPool,
        uint256 winningUnits,
        uint256 totalRedeemed,
        bool isTie,
        bool impaired,
        bool escrowFailed
    );
    event Claimed(address indexed staker, uint256 principal, uint256 yieldShare);

    /* ─────────────────────── User actions ───────────────────── */

    /// @notice Stake USDC on a side. Caller must have approved USDC to this
    ///         contract for at least `amount`. Reverts after lockupEnd or
    ///         if amount is outside the configured bounds.
    function stake(Side side, uint256 amount) external;

    /// @notice Permissionless. Triggers settlement once `block.timestamp >=
    ///         lockupEnd()`. Redeems all of this market's ERC4626 shares;
    ///         snapshots winning side and yield pool. Idempotent.
    /// @dev    If the redeem returns LESS than total principal (yield source
    ///         impaired), payouts are scaled pro-rata so all stakers share
    ///         the loss honestly. yieldPool = max(0, redeemed - principal).
    function settle() external;

    /// @notice Pull-based payout for caller's position. Only callable after
    ///         settlement. Pays principal in all cases (possibly scaled
    ///         down if yield source was impaired); pays yield share only if
    ///         caller is on the winning side.
    function claim() external;

    /* ──────────────────────── Views ─────────────────────────── */

    function questionHash() external view returns (bytes32);
    function question() external view returns (string memory);

    /// @notice The ERC4626 vault this market deposits into. Set at deploy
    ///         time and immutable for the market's life. Different markets
    ///         may use different sources (factory rotates the source it
    ///         uses for new deployments).
    function yieldSource() external view returns (IERC4626);

    function asset() external view returns (IERC20);
    function lockupEnd() external view returns (uint256);
    function settled() external view returns (bool);

    /// @notice Time-weighted units for a side at time `t`.
    ///         Formula: total_units(side, t) = t × totalStaked(side)
    ///                                       − weightedTimeSum(side)
    ///         where weightedTimeSum is the running sum of
    ///         `amount × block.timestamp` over all stakes on that side.
    /// @dev    Also used internally at settlement (with t = lockupEnd).
    function totalUnitsAt(Side side, uint256 t) external view returns (uint256);

    function totalStaked(Side side) external view returns (uint256);
    function position(address staker) external view returns (Position memory);

    /* Set after settle() */
    function winningSide() external view returns (Side);
    function winningUnits() external view returns (uint256);
    function yieldPool() external view returns (uint256);

    /// @notice True if the redeem at settlement returned less than total
    ///         principal. Implies pro-rata principal loss for all stakers.
    function impaired() external view returns (bool);

    /// @notice True if `yieldSource.redeem` reverted at settlement. Stakers
    ///         claim their pro-rata share of the market's ERC4626 shares
    ///         instead of USDC; recovery via the vault is the staker's
    ///         responsibility from there.
    function escrowFailed() external view returns (bool);
}
