// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "openzeppelin-contracts/interfaces/IERC4626.sol";

/// @title ITakesFactory
/// @notice Looks up an existing TakesMarket by question hash or deploys a
///         new one. Markets are addressed by `keccak256(canonical question)`
///         so two callers proposing the same question converge to the same
///         market. Canonicalization is done off-chain (mini-app); the
///         contract trusts the hash.
///
/// @dev Each newly-deployed market is wired to the factory's CURRENT yield
///      source. Markets are immutable once deployed — they keep their
///      original yield source for life. Guardian can rotate the factory's
///      yield source, which only affects markets deployed afterwards.
interface ITakesFactory {
    /* ───────────────────────── Events ───────────────────────── */

    event MarketCreated(
        bytes32 indexed questionHash,
        address indexed market,
        address indexed yieldSource,
        string question,
        address creator
    );

    event YieldSourceUpdated(address indexed previous, address indexed current);
    event GuardianTransferred(address indexed previous, address indexed current);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    /* ─────────────────────── User actions ───────────────────── */

    /// @notice Returns the existing market for `questionHash`, or deploys
    ///         a new one if none exists. The new market is wired to the
    ///         factory's current yield source. The first staker pays the
    ///         creation cost (their tx is typically a multicall:
    ///         getOrCreate + market.stake).
    /// @dev    `question` is only read on first call (deployment). On
    ///         repeat calls the existing market is returned as-is.
    function getOrCreate(
        bytes32 questionHash,
        string calldata question
    ) external returns (address market);

    /* ──────────────────────── Views ─────────────────────────── */

    function getMarket(bytes32 questionHash) external view returns (address);
    function asset() external view returns (IERC20);
    function currentYieldSource() external view returns (IERC4626);
    function guardian() external view returns (address);
    function paused() external view returns (bool);

    /* ──────────────────────── Admin ─────────────────────────── */

    /// @notice GUARDIAN-only. Updates the yield source used for FUTURE
    ///         market deployments. Existing markets are unaffected.
    function setYieldSource(IERC4626 newSource) external;

    /// @notice GUARDIAN-only. Transfer the guardian role.
    function transferGuardian(address newGuardian) external;

    /// @notice GUARDIAN-only. Blocks new market creation. Existing markets
    ///         continue to accept stakes, settle, and pay claims — funds
    ///         are never held hostage.
    function pause() external;
    function unpause() external;
}
