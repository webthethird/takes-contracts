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

    uint256 constant LOCKUP = 30 days;

    function setUp() public {
        usdc = new MockUSDC();
        vaultA = new MockYieldVault(usdc);
        vaultB = new MockYieldVault(usdc);
        factory = new TakesFactory(usdc, vaultA, guardian);
    }

    /* ───────────────────── getOrCreate ─────────────────────── */

    function test_getOrCreate_deploysOnce() public {
        address m1 = factory.getOrCreate(Q1, Q1_TEXT, LOCKUP);
        address m2 = factory.getOrCreate(Q1, Q1_TEXT, LOCKUP);
        assertEq(m1, m2);
        assertTrue(m1 != address(0));
        assertEq(factory.getMarket(Q1, LOCKUP), m1);
    }

    function test_getOrCreate_distinctQuestionsGetDistinctMarkets() public {
        address m1 = factory.getOrCreate(Q1, Q1_TEXT, LOCKUP);
        address m2 = factory.getOrCreate(Q2, Q2_TEXT, LOCKUP);
        assertTrue(m1 != m2);
    }

    function test_marketWiredToCurrentYieldSource() public {
        address m = factory.getOrCreate(Q1, Q1_TEXT, LOCKUP);
        assertEq(address(TakesMarket(m).yieldSource()), address(vaultA));
    }

    function test_emptyQuestionReverts() public {
        vm.expectRevert("empty question");
        factory.getOrCreate(Q1, "", LOCKUP);
    }

    function test_zeroHashRejected() public {
        vm.expectRevert("zero hash");
        factory.getOrCreate(bytes32(0), "anything", LOCKUP);
    }

    function test_hashTextMismatchReverts() public {
        // Hash is for Q1_TEXT but caller passes a different string — must revert.
        vm.expectRevert("hash/text mismatch");
        factory.getOrCreate(Q1, "different question text", LOCKUP);
    }

    /* ──────────────────── CREATE2 determinism ───────────────── */

    function test_predictMarket_matchesActualDeployedAddress() public {
        address predicted = factory.predictMarket(Q1, Q1_TEXT, LOCKUP);
        address actual = factory.getOrCreate(Q1, Q1_TEXT, LOCKUP);
        assertEq(predicted, actual, "CREATE2 prediction must match deployment");
    }

    function test_predictMarket_isStableAcrossMultipleCalls() public {
        address p1 = factory.predictMarket(Q1, Q1_TEXT, LOCKUP);
        address p2 = factory.predictMarket(Q1, Q1_TEXT, LOCKUP);
        assertEq(p1, p2);
    }

    function test_predictMarket_differsAcrossYieldSourceRotation() public {
        // Prediction depends on currentYieldSource (it's part of the initCode).
        address pBefore = factory.predictMarket(Q1, Q1_TEXT, LOCKUP);
        vm.prank(guardian);
        factory.setYieldSource(vaultB);
        address pAfter = factory.predictMarket(Q1, Q1_TEXT, LOCKUP);
        assertTrue(pBefore != pAfter, "rotating yield source should change prediction");
    }

    /* ───────────────────── Yield source rotation ──────────── */

    function test_setYieldSource_affectsOnlyFutureMarkets() public {
        // Deploy m1 under vaultA
        address m1 = factory.getOrCreate(Q1, Q1_TEXT, LOCKUP);
        assertEq(address(TakesMarket(m1).yieldSource()), address(vaultA));

        // Guardian rotates to vaultB
        vm.prank(guardian);
        factory.setYieldSource(vaultB);
        assertEq(address(factory.currentYieldSource()), address(vaultB));

        // m1 is unchanged — still on vaultA
        assertEq(address(TakesMarket(m1).yieldSource()), address(vaultA));

        // m2 deploys under vaultB
        address m2 = factory.getOrCreate(Q2, Q2_TEXT, LOCKUP);
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
        factory.getOrCreate(Q1, Q1_TEXT, LOCKUP);
    }

    function test_pauseDoesNotBlockExistingMarkets() public {
        // Create a market first
        address m = factory.getOrCreate(Q1, Q1_TEXT, LOCKUP);
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
        factory.getOrCreate(Q1, Q1_TEXT, LOCKUP);
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

    /* ──────────────────── factory.stake orchestrator ───────────── */

    uint256 constant STAKE_AMT = 10e6; // $10 USDC

    function _fundAndApprove(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.prank(user);
        usdc.approve(address(factory), type(uint256).max);
    }

    function test_factoryStake_createsMarketAndStakes() public {
        _fundAndApprove(alice, STAKE_AMT);
        // No market exists yet.
        assertEq(factory.getMarket(Q1, LOCKUP), address(0));

        vm.prank(alice);
        address market = factory.stake(Q1, Q1_TEXT, LOCKUP, ITakesMarket.Side.YES, STAKE_AMT);

        // Market was created and registered.
        assertTrue(market != address(0));
        assertEq(factory.getMarket(Q1, LOCKUP), market);
        // Alice is attributed the position, not the factory.
        ITakesMarket.Position memory pos = TakesMarket(market).position(alice);
        assertEq(pos.amount, STAKE_AMT);
        assertEq(uint8(pos.side), uint8(ITakesMarket.Side.YES));
        ITakesMarket.Position memory factoryPos = TakesMarket(market).position(address(factory));
        assertEq(factoryPos.amount, 0);
        // USDC flowed alice → factory → market → yieldSource.
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(address(factory)), 0);
    }

    function test_factoryStake_usesExistingMarket() public {
        // First staker creates the market via the factory orchestrator.
        _fundAndApprove(alice, STAKE_AMT);
        vm.prank(alice);
        address m1 = factory.stake(Q1, Q1_TEXT, LOCKUP, ITakesMarket.Side.YES, STAKE_AMT);

        // Second staker on the same question reuses the market.
        address bob = makeAddr("bob");
        _fundAndApprove(bob, STAKE_AMT);
        vm.prank(bob);
        address m2 = factory.stake(Q1, Q1_TEXT, LOCKUP, ITakesMarket.Side.NO, STAKE_AMT);

        assertEq(m1, m2);
        // Both positions live on the same market.
        ITakesMarket.Position memory aPos = TakesMarket(m1).position(alice);
        ITakesMarket.Position memory bPos = TakesMarket(m1).position(bob);
        assertEq(aPos.amount, STAKE_AMT);
        assertEq(bPos.amount, STAKE_AMT);
        assertEq(uint8(aPos.side), uint8(ITakesMarket.Side.YES));
        assertEq(uint8(bPos.side), uint8(ITakesMarket.Side.NO));
    }

    function test_factoryStake_revertsWithoutAllowance() public {
        usdc.mint(alice, STAKE_AMT);
        // No approve.
        vm.prank(alice);
        vm.expectRevert();
        factory.stake(Q1, Q1_TEXT, LOCKUP, ITakesMarket.Side.YES, STAKE_AMT);
    }

    function test_factoryStake_revertsWithoutBalance() public {
        // Approved but no USDC.
        vm.prank(alice);
        usdc.approve(address(factory), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert();
        factory.stake(Q1, Q1_TEXT, LOCKUP, ITakesMarket.Side.YES, STAKE_AMT);
    }

    function test_factoryStake_revertsWhenPaused() public {
        _fundAndApprove(alice, STAKE_AMT);
        vm.prank(guardian);
        factory.pause();
        vm.prank(alice);
        vm.expectRevert("paused");
        factory.stake(Q1, Q1_TEXT, LOCKUP, ITakesMarket.Side.YES, STAKE_AMT);
    }

    function test_factoryStake_pauseAllowsStakingExistingMarket() public {
        // Existing markets are not held hostage by pause — the orchestrator
        // routes to an existing market without re-creating, so stakes on
        // already-deployed markets keep working.
        _fundAndApprove(alice, STAKE_AMT);
        vm.prank(alice);
        factory.stake(Q1, Q1_TEXT, LOCKUP, ITakesMarket.Side.YES, STAKE_AMT);

        vm.prank(guardian);
        factory.pause();

        address bob = makeAddr("bob");
        _fundAndApprove(bob, STAKE_AMT);
        vm.prank(bob);
        address m = factory.stake(Q1, Q1_TEXT, LOCKUP, ITakesMarket.Side.NO, STAKE_AMT);
        assertTrue(m != address(0));
        assertEq(TakesMarket(m).position(bob).amount, STAKE_AMT);
    }

    function test_factoryStake_allowanceIsConsumedOnlyByAmount() public {
        // Confirm factory uses max-allowance pattern correctly: the
        // force-approve to the market is for `amount` only, not max, so
        // the factory holds no lingering allowance to the market.
        _fundAndApprove(alice, STAKE_AMT);
        vm.prank(alice);
        address market = factory.stake(Q1, Q1_TEXT, LOCKUP, ITakesMarket.Side.YES, STAKE_AMT);
        assertEq(usdc.allowance(address(factory), market), 0);
    }

    /* ──────────────────── market.stakeFor direct ─────────────── */

    function test_stakeFor_attributesToStakerNotCaller() public {
        // Sponsor pays USDC; staker gets the position.
        address sponsor = makeAddr("sponsor");
        usdc.mint(sponsor, STAKE_AMT);

        // Deploy the market via getOrCreate first.
        address marketAddr = factory.getOrCreate(Q1, Q1_TEXT, LOCKUP);
        TakesMarket market = TakesMarket(marketAddr);

        vm.prank(sponsor);
        usdc.approve(marketAddr, type(uint256).max);

        vm.prank(sponsor);
        market.stakeFor(alice, ITakesMarket.Side.YES, STAKE_AMT);

        // Position on alice, not sponsor.
        assertEq(market.position(alice).amount, STAKE_AMT);
        assertEq(market.position(sponsor).amount, 0);
        // USDC came from sponsor.
        assertEq(usdc.balanceOf(sponsor), 0);
    }

    function test_stakeFor_zeroStakerReverts() public {
        address marketAddr = factory.getOrCreate(Q1, Q1_TEXT, LOCKUP);
        TakesMarket market = TakesMarket(marketAddr);
        usdc.mint(address(this), STAKE_AMT);
        usdc.approve(marketAddr, type(uint256).max);
        vm.expectRevert("staker zero");
        market.stakeFor(address(0), ITakesMarket.Side.YES, STAKE_AMT);
    }

    function test_stakeFor_oppositeSideReverts() public {
        // Multi-stake on the same side is allowed; an opposite-side
        // stake against the same address must revert. Closes the
        // direct-stakeFor variant of the side-lock invariant.
        address marketAddr = factory.getOrCreate(Q1, Q1_TEXT, LOCKUP);
        TakesMarket market = TakesMarket(marketAddr);
        _fundAndApprove(alice, STAKE_AMT * 2);
        vm.prank(alice);
        factory.stake(Q1, Q1_TEXT, LOCKUP, ITakesMarket.Side.YES, STAKE_AMT);

        address sponsor = makeAddr("sponsor");
        usdc.mint(sponsor, STAKE_AMT);
        vm.prank(sponsor);
        usdc.approve(marketAddr, type(uint256).max);
        vm.prank(sponsor);
        vm.expectRevert("side locked");
        market.stakeFor(alice, ITakesMarket.Side.NO, STAKE_AMT);
    }

    /* ──────────────────── configurable lockup ─────────────────── */

    function test_lockup_sameQuestionDifferentLockupsAreDistinctMarkets() public {
        // Two markets on the same question with different lockups must
        // resolve to different addresses.
        uint256 shortLockup = 7 days;
        uint256 longLockup = 90 days;

        address mShort = factory.getOrCreate(Q1, Q1_TEXT, shortLockup);
        address mLong = factory.getOrCreate(Q1, Q1_TEXT, longLockup);
        assertTrue(mShort != mLong, "lockup must change the market address");

        // Each lookup is keyed by (hash, duration)
        assertEq(factory.getMarket(Q1, shortLockup), mShort);
        assertEq(factory.getMarket(Q1, longLockup), mLong);
        assertEq(factory.getMarket(Q1, 30 days), address(0));

        // Each market reports its own lockup duration.
        assertEq(TakesMarket(mShort).lockupDuration(), shortLockup);
        assertEq(TakesMarket(mLong).lockupDuration(), longLockup);
    }

    function test_lockup_belowMinReverts() public {
        uint256 tooShort = factory.MIN_LOCKUP_DURATION() - 1;
        vm.expectRevert("lockup out of bounds");
        factory.getOrCreate(Q1, Q1_TEXT, tooShort);
    }

    function test_lockup_aboveMaxReverts() public {
        uint256 tooLong = factory.MAX_LOCKUP_DURATION() + 1;
        vm.expectRevert("lockup out of bounds");
        factory.getOrCreate(Q1, Q1_TEXT, tooLong);
    }

    function test_lockup_boundsAreInclusive() public {
        uint256 minLockup = factory.MIN_LOCKUP_DURATION();
        uint256 maxLockup = factory.MAX_LOCKUP_DURATION();
        // Min and max are both valid.
        address mMin = factory.getOrCreate(Q1, Q1_TEXT, minLockup);
        address mMax = factory.getOrCreate(Q2, Q2_TEXT, maxLockup);
        assertTrue(mMin != address(0));
        assertTrue(mMax != address(0));
    }

    function test_predictMarket_lockupParamAffectsAddress() public {
        address p30 = factory.predictMarket(Q1, Q1_TEXT, 30 days);
        address p90 = factory.predictMarket(Q1, Q1_TEXT, 90 days);
        assertTrue(p30 != p90, "different lockup must yield different prediction");
        // Predictions are stable and match actual deployments at each lockup.
        assertEq(p30, factory.getOrCreate(Q1, Q1_TEXT, 30 days));
        assertEq(p90, factory.getOrCreate(Q1, Q1_TEXT, 90 days));
    }

    function test_factoryStake_lockupOutOfBoundsReverts() public {
        _fundAndApprove(alice, STAKE_AMT);
        uint256 tooLong = factory.MAX_LOCKUP_DURATION() + 1;
        vm.prank(alice);
        vm.expectRevert("lockup out of bounds");
        factory.stake(Q1, Q1_TEXT, tooLong, ITakesMarket.Side.YES, STAKE_AMT);
    }
}
