// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { TakesFactory } from "../src/TakesFactory.sol";
import { TakesMarket } from "../src/TakesMarket.sol";
import { ITakesMarket } from "../src/interfaces/ITakesMarket.sol";
import { MockUSDC } from "./mocks/MockUSDC.sol";
import { MockYieldVault } from "./mocks/MockYieldVault.sol";

contract TakesFactoryTest is Test {
    MockUSDC usdc;
    MockYieldVault vaultA;
    MockYieldVault vaultB;
    TakesFactory factory;

    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");

    string constant Q1_TEXT = "question one";
    string constant Q2_TEXT = "question two";
    bytes32 constant Q1 = keccak256(bytes(Q1_TEXT));
    bytes32 constant Q2 = keccak256(bytes(Q2_TEXT));

    function setUp() public {
        usdc = new MockUSDC();
        vaultA = new MockYieldVault(usdc);
        vaultB = new MockYieldVault(usdc);
        factory = new TakesFactory(usdc, vaultA, guardian);
    }

    /* ───────────────────── getOrCreate ─────────────────────── */

    function test_getOrCreate_deploysOnce() public {
        address m1 = factory.getOrCreate(Q1, Q1_TEXT);
        address m2 = factory.getOrCreate(Q1, Q1_TEXT);
        assertEq(m1, m2);
        assertTrue(m1 != address(0));
        assertEq(factory.getMarket(Q1), m1);
    }

    function test_getOrCreate_distinctQuestionsGetDistinctMarkets() public {
        address m1 = factory.getOrCreate(Q1, Q1_TEXT);
        address m2 = factory.getOrCreate(Q2, Q2_TEXT);
        assertTrue(m1 != m2);
    }

    function test_marketWiredToCurrentYieldSource() public {
        address m = factory.getOrCreate(Q1, Q1_TEXT);
        assertEq(address(TakesMarket(m).yieldSource()), address(vaultA));
    }

    function test_emptyQuestionReverts() public {
        vm.expectRevert("empty question");
        factory.getOrCreate(Q1, "");
    }

    function test_zeroHashRejected() public {
        vm.expectRevert("zero hash");
        factory.getOrCreate(bytes32(0), "anything");
    }

    function test_hashTextMismatchReverts() public {
        // Hash is for Q1_TEXT but caller passes a different string — must revert.
        vm.expectRevert("hash/text mismatch");
        factory.getOrCreate(Q1, "different question text");
    }

    /* ───────────────────── Yield source rotation ──────────── */

    function test_setYieldSource_affectsOnlyFutureMarkets() public {
        // Deploy m1 under vaultA
        address m1 = factory.getOrCreate(Q1, Q1_TEXT);
        assertEq(address(TakesMarket(m1).yieldSource()), address(vaultA));

        // Guardian rotates to vaultB
        vm.prank(guardian);
        factory.setYieldSource(vaultB);
        assertEq(address(factory.currentYieldSource()), address(vaultB));

        // m1 is unchanged — still on vaultA
        assertEq(address(TakesMarket(m1).yieldSource()), address(vaultA));

        // m2 deploys under vaultB
        address m2 = factory.getOrCreate(Q2, Q2_TEXT);
        assertEq(address(TakesMarket(m2).yieldSource()), address(vaultB));
    }

    function test_setYieldSource_onlyGuardian() public {
        vm.prank(attacker);
        vm.expectRevert("not guardian");
        factory.setYieldSource(vaultB);
    }

    function test_setYieldSource_rejectsAssetMismatch() public {
        // Deploy a vault wrapping a different token
        MockUSDC otherToken = new MockUSDC();
        MockYieldVault wrongAsset = new MockYieldVault(otherToken);
        vm.prank(guardian);
        vm.expectRevert("asset mismatch");
        factory.setYieldSource(wrongAsset);
    }

    /* ───────────────────────── Pause ───────────────────────── */

    function test_pauseBlocksNewMarketCreation() public {
        vm.prank(guardian);
        factory.pause();
        vm.expectRevert("paused");
        factory.getOrCreate(Q1, Q1_TEXT);
    }

    function test_pauseDoesNotBlockExistingMarkets() public {
        // Create a market first
        address m = factory.getOrCreate(Q1, Q1_TEXT);
        TakesMarket market = TakesMarket(m);

        // Pause the factory
        vm.prank(guardian);
        factory.pause();

        // Existing market still accepts stakes
        usdc.mint(alice, 10e6);
        vm.prank(alice);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(alice);
        market.stake(ITakesMarket.Side.YES, 10e6);

        assertEq(market.totalStaked(ITakesMarket.Side.YES), 10e6);
    }

    function test_pause_onlyGuardian() public {
        vm.prank(attacker);
        vm.expectRevert("not guardian");
        factory.pause();
    }

    function test_unpause_restoresCreation() public {
        vm.prank(guardian);
        factory.pause();
        vm.prank(guardian);
        factory.unpause();
        // Should succeed
        factory.getOrCreate(Q1, Q1_TEXT);
    }

    /* ─────────────────── Guardian transfer (2-step) ───────────────── */

    function test_transferGuardian_twoStep() public {
        address newGuardian = makeAddr("newGuardian");

        // Step 1: current guardian nominates
        vm.prank(guardian);
        factory.transferGuardian(newGuardian);
        assertEq(factory.pendingGuardian(), newGuardian);
        // Old guardian still in control until accept
        assertEq(factory.guardian(), guardian);
        vm.prank(guardian);
        factory.pause();
        vm.prank(guardian);
        factory.unpause();

        // Step 2: new guardian accepts
        vm.prank(newGuardian);
        factory.acceptGuardian();
        assertEq(factory.guardian(), newGuardian);
        assertEq(factory.pendingGuardian(), address(0));

        // Old guardian no longer authorized
        vm.prank(guardian);
        vm.expectRevert("not guardian");
        factory.pause();

        // New one is
        vm.prank(newGuardian);
        factory.pause();
    }

    function test_transferGuardian_onlyGuardianCanNominate() public {
        vm.prank(attacker);
        vm.expectRevert("not guardian");
        factory.transferGuardian(attacker);
    }

    function test_acceptGuardian_onlyPending() public {
        address newGuardian = makeAddr("newGuardian");
        vm.prank(guardian);
        factory.transferGuardian(newGuardian);
        // Wrong caller
        vm.prank(attacker);
        vm.expectRevert("not pending");
        factory.acceptGuardian();
    }

    function test_acceptGuardian_revertsWithNoPending() public {
        vm.prank(makeAddr("anyone"));
        vm.expectRevert("no pending");
        factory.acceptGuardian();
    }

    function test_transferGuardian_canBeCancelled() public {
        address candidate = makeAddr("candidate");
        vm.prank(guardian);
        factory.transferGuardian(candidate);
        assertEq(factory.pendingGuardian(), candidate);
        // Cancel by re-setting to address(0)
        vm.prank(guardian);
        factory.transferGuardian(address(0));
        assertEq(factory.pendingGuardian(), address(0));
        // Candidate can no longer accept
        vm.prank(candidate);
        vm.expectRevert("no pending");
        factory.acceptGuardian();
    }
}
