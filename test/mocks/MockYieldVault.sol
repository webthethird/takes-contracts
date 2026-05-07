// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20, IERC20Metadata } from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Test-only ERC4626 vault wrapping an underlying mintable token.
///         Yield is simulated by directly minting underlying to the vault
///         (raises totalAssets without minting shares → price-per-share up).
///         Losses are simulated by burning underlying from the vault.
contract MockYieldVault is ERC4626 {
    constructor(IERC20 _underlying)
        ERC20("Mock Yield Vault", "yvUSDC")
        ERC4626(_underlying)
    {}

    /// @notice Test helper: simulate yield by injecting `amount` of underlying.
    ///         Caller must have approved this vault for the amount.
    function accrueYield(uint256 amount) external {
        IERC20 underlying = IERC20(asset());
        underlying.transferFrom(msg.sender, address(this), amount);
        // No shares minted → existing shares now redeem for more underlying.
    }

    /// @notice Test helper: simulate vault impairment (loss).
    function incurLoss(uint256 amount) external {
        // ERC20 doesn't have public burn; transfer to a black hole address
        IERC20 underlying = IERC20(asset());
        underlying.transfer(address(0xdead), amount);
    }
}
