// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "openzeppelin-contracts/interfaces/IERC4626.sol";
import { TakesFactory } from "../src/TakesFactory.sol";
import { MockUSDC } from "../test/mocks/MockUSDC.sol";
import { MockYieldVault } from "../test/mocks/MockYieldVault.sol";

/// @title Deploy
/// @notice Deploys TakesFactory. Chain-aware:
///         - Base mainnet (8453): uses real USDC; YIELD_SOURCE env required.
///         - Base Sepolia (84532): if YIELD_SOURCE is unset, also deploys a
///           MockUSDC + MockYieldVault and uses those for end-to-end testing.
///
/// Usage:
///   # Base Sepolia (testnet, deploys mocks):
///   GUARDIAN=0x... forge script script/Deploy.s.sol \
///       --rpc-url base_sepolia --broadcast --private-key $DEPLOY_PRIVATE_KEY
///
///   # Base mainnet (production):
///   GUARDIAN=0x... YIELD_SOURCE=0x... forge script script/Deploy.s.sol \
///       --rpc-url base --broadcast --verify --private-key $DEPLOY_PRIVATE_KEY
contract Deploy is Script {
    /// @notice Circle USDC on Base mainnet
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @notice Circle USDC on Base Sepolia testnet
    address constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external {
        // Resolve guardian (required — no silent default for the security role)
        address guardian = vm.envAddress("GUARDIAN");
        require(guardian != address(0), "GUARDIAN env required");

        // Resolve USDC: env override or chain default. address(0) means unset.
        address usdc = vm.envOr("USDC", address(0));
        if (usdc == address(0)) {
            if (block.chainid == 8453) usdc = BASE_USDC;
            else if (block.chainid == 84532) usdc = BASE_SEPOLIA_USDC;
            // else: leave as 0; mock branch below deploys MockUSDC.
        }

        // Resolve yield source: env override or deploy a mock on testnets.
        address yieldSource = vm.envOr("YIELD_SOURCE", address(0));
        bool deployMockUsdc = usdc == address(0);
        bool deployMockVault = yieldSource == address(0);

        if (deployMockVault && block.chainid == 8453) {
            revert("Refusing to deploy mock vault on mainnet - set YIELD_SOURCE");
        }
        if (deployMockUsdc && block.chainid == 8453) {
            revert("USDC env required on mainnet");
        }

        // Read deployer key — used to broadcast and to mint testnet USDC.
        // Falls back to forge's --private-key flag if env not set.
        uint256 deployerKey = vm.envOr("DEPLOY_PRIVATE_KEY", uint256(0));
        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast();
        }

        if (deployMockUsdc) {
            MockUSDC mockUsdc = new MockUSDC();
            usdc = address(mockUsdc);
            console.log("MockUSDC:        ", usdc);
        }

        if (deployMockVault) {
            MockYieldVault mockVault = new MockYieldVault(IERC20(usdc));
            yieldSource = address(mockVault);
            console.log("MockYieldVault:  ", yieldSource);
        }

        TakesFactory factory = new TakesFactory(
            IERC20(usdc),
            IERC4626(yieldSource),
            guardian
        );

        vm.stopBroadcast();

        console.log("=== Deployment ===");
        console.log("Chain ID:        ", block.chainid);
        console.log("USDC:            ", usdc);
        console.log("Yield source:    ", yieldSource);
        console.log("Guardian:        ", guardian);
        console.log("TakesFactory:    ", address(factory));
    }
}
