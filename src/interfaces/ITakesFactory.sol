// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITakesMarket } from "./ITakesMarket.sol";

/// @title ITakesFactory
/// @notice Looks up an existing TakesMarket by question hash or deploys a
///         new one on first call. Markets are addressed by
///         `keccak256(canonicalized question text)` so two callers proposing
///         the same question converge to the same market.
interface ITakesFactory {
    /* ───────────────────────── Events ───────────────────────── */

    event MarketCreated(
        bytes32 indexed questionHash,
        address indexed market,
        ITakesMarket.ClaimType claimType,
        string question,
        address creator
    );

    /* ─────────────────────── User actions ───────────────────── */

    /// @notice Returns the existing market for `questionHash`, or deploys a
    ///         new one if none exists. The first staker pays the creation
    ///         cost (single multicall: getOrCreate + market.stake).
    /// @dev    `question` and `claimType` are only used when deploying; on a
    ///         repeat call they are ignored (existing market is returned
    ///         as-is). Callers can verify the existing market matches their
    ///         expectations via the returned address.
    function getOrCreate(
        bytes32 questionHash,
        string calldata question,
        ITakesMarket.ClaimType claimType
    ) external returns (address market);

    /* ──────────────────────── Views ─────────────────────────── */

    function getMarket(bytes32 questionHash) external view returns (address);
    function vault() external view returns (address);
}
