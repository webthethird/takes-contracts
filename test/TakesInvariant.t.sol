// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { TakesFactory } from "../src/TakesFactory.sol";
import { TakesMarket } from "../src/TakesMarket.sol";
import { ITakesMarket } from "../src/interfaces/ITakesMarket.sol";
import { MockUSDC } from "./mocks/MockUSDC.sol";
import { MockYieldVault } from "./mocks/MockYieldVault.sol";

/// @notice Handler that issues randomized actions against a single market.
///         All actions early-return on invalid preconditions instead of
///         reverting, so randomized fuzz traces don't get stuck on
///         uninteresting reverts.
contract TakesHandler is Test {
    TakesMarket public immutable market;
    MockUSDC public immutable usdc;
    MockYieldVault public immutable vault;
    address[] public users;

    // Ghost variables for solvency invariants
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalClaimed;
    uint256 public ghost_yieldInjected;
    uint256 public ghost_lossInjected;

    // Per-user state we maintain externally for visibility
    mapping(address => bool) public hasStaked;
    mapping(address => bool) public hasClaimed;

    constructor(
        TakesMarket _market,
        MockUSDC _usdc,
        MockYieldVault _vault,
        address[] memory _users
    ) {
        market = _market;
        usdc = _usdc;
        vault = _vault;
        users = _users;
        for (uint256 i = 0; i < _users.length; i++) {
            _usdc.mint(_users[i], 1_000_000e6);
            vm.prank(_users[i]);
            _usdc.approve(address(_market), type(uint256).max);
        }
    }

    function stake(uint256 userIdx, uint256 amount, bool yesSide) external {
        userIdx = bound(userIdx, 0, users.length - 1);
        address user = users[userIdx];
        if (hasStaked[user]) return;
        if (block.timestamp >= market.lockupEnd()) return;
        amount = bound(amount, market.MIN_STAKE(), market.MAX_STAKE());

        vm.prank(user);
        try market.stake(
            yesSide ? ITakesMarket.Side.YES : ITakesMarket.Side.NO,
            amount
        ) {
            hasStaked[user] = true;
            ghost_totalDeposited += amount;
        } catch {
            // Don't crash the fuzz run on rare ordering bugs; let invariants
            // assertion catch underlying issues
        }
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1, 5 days);
        vm.warp(block.timestamp + secs);
    }

    function injectYield(uint256 amount) external {
        amount = bound(amount, 0, 100e6);
        if (amount == 0) return;
        // Mint the underlying directly to this handler, then accrue into vault
        usdc.mint(address(this), amount);
        usdc.approve(address(vault), amount);
        try vault.accrueYield(amount) {
            ghost_yieldInjected += amount;
        } catch {}
    }

    function injectLoss(uint256 amount) external {
        // Cap loss to ≤ vault balance to avoid trivially-impossible losses
        uint256 vaultBal = usdc.balanceOf(address(vault));
        amount = bound(amount, 0, vaultBal / 4); // up to 25% loss
        if (amount == 0) return;
        try vault.incurLoss(amount) {
            ghost_lossInjected += amount;
        } catch {}
    }

    function settle() external {
        if (block.timestamp < market.lockupEnd()) return;
        if (market.settled()) return;
        try market.settle() {} catch {}
    }

    function claim(uint256 userIdx) external {
        userIdx = bound(userIdx, 0, users.length - 1);
        address user = users[userIdx];
        if (!market.settled()) return;
        if (hasClaimed[user]) return;
        ITakesMarket.Position memory pos = market.position(user);
        if (pos.amount == 0) return;

        uint256 before = usdc.balanceOf(user);
        vm.prank(user);
        try market.claim() {
            uint256 got = usdc.balanceOf(user) - before;
            ghost_totalClaimed += got;
            hasClaimed[user] = true;
        } catch {}
    }
}

contract TakesInvariantTest is Test {
    TakesHandler handler;
    TakesMarket market;
    MockUSDC usdc;
    MockYieldVault vault;

    address constant USER_1 = address(0xA1);
    address constant USER_2 = address(0xA2);
    address constant USER_3 = address(0xA3);
    address constant USER_4 = address(0xA4);
    address constant USER_5 = address(0xA5);

    function setUp() public {
        usdc = new MockUSDC();
        vault = new MockYieldVault(usdc);
        TakesFactory factory = new TakesFactory(usdc, vault, address(this));
        market = TakesMarket(
            factory.getOrCreate(keccak256("invariant test"), "Invariant test")
        );

        address[] memory users = new address[](5);
        users[0] = USER_1;
        users[1] = USER_2;
        users[2] = USER_3;
        users[3] = USER_4;
        users[4] = USER_5;

        handler = new TakesHandler(market, usdc, vault, users);

        // Direct fuzzer at the handler's interface
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = TakesHandler.stake.selector;
        selectors[1] = TakesHandler.warp.selector;
        selectors[2] = TakesHandler.injectYield.selector;
        selectors[3] = TakesHandler.injectLoss.selector;
        selectors[4] = TakesHandler.settle.selector;
        selectors[5] = TakesHandler.claim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// @notice Total USDC paid out to claimers must never exceed
    ///         total deposits + yield injected. Captures the fundamental
    ///         solvency property: we don't print money.
    function invariant_solvency() public view {
        uint256 maxOut =
            handler.ghost_totalDeposited() + handler.ghost_yieldInjected();
        assertLe(
            handler.ghost_totalClaimed(),
            maxOut,
            "claims exceed deposits + yield"
        );
    }

    /// @notice Pre-settlement, the side aggregates equal the total deposited.
    ///         (Post-settlement, no more stakes can change them either way.)
    function invariant_stakeAccounting() public view {
        uint256 sumSides =
            market.totalStaked(ITakesMarket.Side.YES) +
            market.totalStaked(ITakesMarket.Side.NO);
        assertEq(
            sumSides,
            handler.ghost_totalDeposited(),
            "side totals != deposits"
        );
    }

    /// @notice Once settled, settled() stays true. Sanity check that settle
    ///         is one-way.
    function invariant_settledIsLatching() public view {
        if (handler.ghost_totalClaimed() > 0) {
            // Some claim happened, which requires settled() to be true at
            // some point — and settled() is set true permanently.
            assertTrue(market.settled());
        }
    }

    /// @notice Stake amounts are always within bounds for any recorded position.
    function invariant_positionBounds() public view {
        address[5] memory addrs = [USER_1, USER_2, USER_3, USER_4, USER_5];
        for (uint256 i = 0; i < addrs.length; i++) {
            ITakesMarket.Position memory pos = market.position(addrs[i]);
            if (pos.amount > 0) {
                assertGe(uint256(pos.amount), market.MIN_STAKE());
                assertLe(uint256(pos.amount), market.MAX_STAKE());
            }
        }
    }

    /// @notice The time-weighted units identity must hold for the timestamp
    ///         the contract uses internally at settlement.
    function invariant_unitIdentityAtLockupEnd() public view {
        if (!market.settled()) return;
        // We can recompute units at lockupEnd and check against winningUnits
        // (when there's a winner; ties combine).
        uint256 yesUnits = market.totalUnitsAt(ITakesMarket.Side.YES, market.lockupEnd());
        uint256 noUnits = market.totalUnitsAt(ITakesMarket.Side.NO, market.lockupEnd());
        if (market.isTie()) {
            assertEq(market.winningUnits(), yesUnits + noUnits);
        } else if (market.winningSide() == ITakesMarket.Side.YES) {
            assertEq(market.winningUnits(), yesUnits);
            assertGt(yesUnits, noUnits);
        } else {
            assertEq(market.winningUnits(), noUnits);
            assertGt(noUnits, yesUnits);
        }
    }
}
