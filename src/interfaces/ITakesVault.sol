// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITakesVault
/// @notice Single shared escrow contract that holds all USDC across all
///         markets. Routes deposits to a configurable ERC4626 yield source
///         (e.g., a Morpho Vault on Base). At settlement, a market unwinds
///         its share of the vault's deposit and reclaims principal + yield.
///
/// @dev The vault tracks per-market USDC accounting in two parts:
///        - principalOf(market):       sum of stakes that haven't settled
///        - sharesOf(market):          ERC4626 shares attributable to market
///      At settlement, the market calls `unwind(...)` which redeems its
///      shares for USDC, transfers principal + yield back, and zeroes both
///      ledgers for that market.
///
///      Yield source can be migrated by GUARDIAN: pause new deposits, redeem
///      all open shares, swap source, re-deposit. Implementation detail of
///      the vault, transparent to markets.
interface ITakesVault {
    /* ───────────────────────── Events ───────────────────────── */

    event MarketRegistered(address indexed market);
    event Deposited(address indexed market, uint256 usdc, uint256 shares);
    event Unwound(address indexed market, uint256 usdc, uint256 yield);
    event YieldSourceMigrated(address indexed from, address indexed to);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    /* ─────────────────────── Market actions ─────────────────── */

    /// @notice Called by markets when a user stakes. The market has
    ///         already received USDC from the user; this transfers it
    ///         to the vault and routes to the yield source.
    function deposit(uint256 usdc) external returns (uint256 shares);

    /// @notice Called by a market at settlement time. Redeems the market's
    ///         entire share balance, returns USDC (principal + yield) to
    ///         the calling market, and clears the market's accounting.
    /// @return usdcReturned total USDC sent back to the market
    /// @return yieldReturned the portion that's yield (above principal)
    function unwind() external returns (uint256 usdcReturned, uint256 yieldReturned);

    /* ──────────────────────── Views ─────────────────────────── */

    function principalOf(address market) external view returns (uint256);
    function sharesOf(address market) external view returns (uint256);
    function yieldSource() external view returns (address);
    function isMarket(address market) external view returns (bool);
    function paused() external view returns (bool);

    /* ──────────────────────── Admin ─────────────────────────── */

    /// @notice Register a new market as authorized to call deposit/unwind.
    ///         Called by the factory on market deployment.
    function registerMarket(address market) external;

    /// @notice GUARDIAN can pause new deposits if something looks wrong.
    ///         Settlement and claims are not blocked — funds remain reachable.
    function pause() external;
    function unpause() external;

    /// @notice GUARDIAN-only. Migrate to a different ERC4626 vault.
    ///         Atomic: redeem everything from old, re-deposit to new.
    function migrateYieldSource(address newSource) external;
}
