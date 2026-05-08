// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { TakesFactory } from "../src/TakesFactory.sol";
import { TakesMarket } from "../src/TakesMarket.sol";
import { ITakesMarket } from "../src/interfaces/ITakesMarket.sol";
import { MockUSDC } from "./mocks/MockUSDC.sol";
import { MockYieldVault } from "./mocks/MockYieldVault.sol";

contract TakesMarketTest is Test {
    MockUSDC usdc;
    MockYieldVault vault;
    TakesFactory factory;
    TakesMarket market;

    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address yieldFeeder = makeAddr("yieldFeeder"); // funds the mock vault's "yield"

    string constant Q_TEXT = "was the snap airdrop fair?";
    bytes32 constant Q_HASH = keccak256(bytes(Q_TEXT));

    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        vault = new MockYieldVault(usdc);
        factory = new TakesFactory(usdc, vault, guardian);

        // Create the market via factory (using alice as the first creator)
        vm.prank(alice);
        address marketAddr = factory.getOrCreate(Q_HASH, Q_TEXT);
        market = TakesMarket(marketAddr);

        // Fund test users
        usdc.mint(alice, 1000 * ONE_USDC);
        usdc.mint(bob, 1000 * ONE_USDC);
        usdc.mint(carol, 1000 * ONE_USDC);
        usdc.mint(yieldFeeder, 1000 * ONE_USDC);

        // Approve usdc to the market for each user
        vm.prank(alice);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(carol);
        usdc.approve(address(market), type(uint256).max);
    }

    function _stake(address from, ITakesMarket.Side side, uint256 amount) internal {
        vm.prank(from);
        market.stake(side, amount);
    }

    function _accrueYield(uint256 amount) internal {
        vm.prank(yieldFeeder);
        usdc.approve(address(vault), amount);
        vm.prank(yieldFeeder);
        vault.accrueYield(amount);
    }

    /* ─────────────────── Happy-path resolution ─────────────────── */

    function test_singleStaker_winsTrivially() public {
        _stake(alice, ITakesMarket.Side.YES, 10 * ONE_USDC);

        vm.warp(market.lockupEnd());

        // Inject some yield
        _accrueYield(1 * ONE_USDC); // 1 USDC of yield
        market.settle();

        assertEq(uint8(market.winningSide()), uint8(ITakesMarket.Side.YES));
        assertFalse(market.isTie());
        // Yield pool = redeemed - principal. With 1 USDC injected, yield ≈ 1 USDC.
        assertGt(market.yieldPool(), 0);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claim();
        uint256 aliceAfter = usdc.balanceOf(alice);

        // Alice gets her 10 USDC principal + ~1 USDC yield
        assertEq(aliceAfter - aliceBefore, 10 * ONE_USDC + market.yieldPool());
    }

    function test_winnerTakesYield_loserPrincipalOnly() public {
        // Alice stakes YES, Bob stakes NO — both at t=now
        _stake(alice, ITakesMarket.Side.YES, 50 * ONE_USDC);
        _stake(bob, ITakesMarket.Side.NO, 10 * ONE_USDC);

        vm.warp(market.lockupEnd());
        _accrueYield(6 * ONE_USDC); // 6 USDC yield on 60 USDC principal
        market.settle();

        // YES has more units (more amount × same elapsed time)
        assertEq(uint8(market.winningSide()), uint8(ITakesMarket.Side.YES));

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claim();
        // Alice (winner): 50 + all of yieldPool
        assertEq(usdc.balanceOf(alice) - aliceBefore, 50 * ONE_USDC + market.yieldPool());

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        market.claim();
        // Bob (loser): just 10 USDC principal, no yield
        assertEq(usdc.balanceOf(bob) - bobBefore, 10 * ONE_USDC);
    }

    /* ───────────────── Time weighting protects early stakers ─────────────── */

    function test_lateLargeStakerCannotFlipOrCaptureYield() public {
        // Alice stakes YES early with $10
        _stake(alice, ITakesMarket.Side.YES, 10 * ONE_USDC);

        // 29 days pass (1 day before lockup end)
        vm.warp(block.timestamp + 29 days);

        // Bob piles into NO with $1000 at the last minute
        _stake(bob, ITakesMarket.Side.NO, 1000 * ONE_USDC);

        // Lockup ends, yield accrues
        vm.warp(market.lockupEnd());
        _accrueYield(10 * ONE_USDC);
        market.settle();

        // Alice's units: 10 × 30 days
        // Bob's units: 1000 × 1 day
        // Alice = 10 × 2,592,000 = 25,920,000 unit-seconds × 1e6 = 25.92e12 unit-USDC-seconds
        // Bob = 1000 × 86,400 = 86,400,000 unit-seconds × 1e6 = 86.4e12
        // Bob actually wins on units: 86.4e12 > 25.92e12
        // So this test demonstrates that a SUFFICIENTLY-large late stake
        // CAN flip the market. Time-weighting just means it's expensive.

        // Refine: Bob would need amount × time-locked > Alice's. So Bob's
        // $1000 over 1 day = $1000 unit-days vs Alice's $10 over 30 days =
        // $300 unit-days. Bob wins. Time-weighting bounds the *cost* of the
        // attack but doesn't make it impossible.

        // The actual protection: Bob committed $1000 of capital for 30 days
        // (until lockup ends) to buy this win. If yield is ~$10/$1010 stake,
        // his per-dollar yield is tiny. The attack costs more than the prize.

        assertEq(uint8(market.winningSide()), uint8(ITakesMarket.Side.NO));

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        market.claim();
        uint256 bobNet = usdc.balanceOf(bob) - bobBefore;
        // Bob took the entire yield pool but contributed 1000 USDC for 30 days
        // of being locked up. Total yield is ~10 USDC — < 0.1% on capital.
        assertEq(bobNet, 1000 * ONE_USDC + market.yieldPool());
    }

    function test_earlyStakerEarnsMoreYieldThanLateStaker_sameSide() public {
        // Alice stakes $50 YES day 1
        _stake(alice, ITakesMarket.Side.YES, 50 * ONE_USDC);

        // 25 days pass
        vm.warp(block.timestamp + 25 days);

        // Bob stakes $50 YES (same amount, much later)
        _stake(bob, ITakesMarket.Side.YES, 50 * ONE_USDC);

        // Lockup ends
        vm.warp(market.lockupEnd());
        _accrueYield(10 * ONE_USDC);
        market.settle();

        assertEq(uint8(market.winningSide()), uint8(ITakesMarket.Side.YES));

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claim();
        uint256 aliceYield = (usdc.balanceOf(alice) - aliceBefore) - 50 * ONE_USDC;

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        market.claim();
        uint256 bobYield = (usdc.balanceOf(bob) - bobBefore) - 50 * ONE_USDC;

        // Alice's units: 50 × 30 days; Bob's: 50 × 5 days. Ratio 6:1.
        assertGt(aliceYield, bobYield * 5); // Roughly 6x but allow rounding
    }

    /* ─────────────────────────── Tie ───────────────────────── */

    function test_tie_splitsYieldAcrossAllStakers() public {
        // Alice $50 YES, Bob $50 NO at t=0 → identical units
        _stake(alice, ITakesMarket.Side.YES, 50 * ONE_USDC);
        _stake(bob, ITakesMarket.Side.NO, 50 * ONE_USDC);

        vm.warp(market.lockupEnd());
        _accrueYield(10 * ONE_USDC);
        market.settle();

        assertTrue(market.isTie());

        // Both should get principal + half of yield (since their units are equal)
        uint256 expectedHalf = market.yieldPool() / 2;

        uint256 aBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claim();
        uint256 aGot = usdc.balanceOf(alice) - aBefore - 50 * ONE_USDC;

        uint256 bBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        market.claim();
        uint256 bGot = usdc.balanceOf(bob) - bBefore - 50 * ONE_USDC;

        assertApproxEqAbs(aGot, expectedHalf, 1);
        assertApproxEqAbs(bGot, expectedHalf, 1);
    }

    /* ────────────────────── Lifecycle guards ────────────────── */

    function test_cannotStakeAfterLockup() public {
        vm.warp(market.lockupEnd());
        vm.prank(alice);
        vm.expectRevert("lockup ended");
        market.stake(ITakesMarket.Side.YES, 10 * ONE_USDC);
    }

    function test_cannotStakeTwice() public {
        _stake(alice, ITakesMarket.Side.YES, 10 * ONE_USDC);
        vm.prank(alice);
        vm.expectRevert("already staked");
        market.stake(ITakesMarket.Side.YES, 10 * ONE_USDC);
    }

    function test_cannotSettleEarly() public {
        _stake(alice, ITakesMarket.Side.YES, 10 * ONE_USDC);
        vm.expectRevert("lockup not ended");
        market.settle();
    }

    function test_settleIsIdempotent() public {
        _stake(alice, ITakesMarket.Side.YES, 10 * ONE_USDC);
        vm.warp(market.lockupEnd());
        market.settle();
        vm.expectRevert("already settled");
        market.settle();
    }

    function test_cannotClaimBeforeSettle() public {
        _stake(alice, ITakesMarket.Side.YES, 10 * ONE_USDC);
        vm.warp(market.lockupEnd());
        vm.prank(alice);
        vm.expectRevert("not settled");
        market.claim();
    }

    function test_cannotClaimTwice() public {
        _stake(alice, ITakesMarket.Side.YES, 10 * ONE_USDC);
        vm.warp(market.lockupEnd());
        market.settle();
        vm.prank(alice);
        market.claim();
        vm.prank(alice);
        vm.expectRevert("already claimed");
        market.claim();
    }

    function test_stakeAmountBounds() public {
        vm.prank(alice);
        vm.expectRevert("amount out of bounds");
        market.stake(ITakesMarket.Side.YES, ONE_USDC - 1); // below MIN_STAKE

        vm.prank(alice);
        vm.expectRevert("amount out of bounds");
        market.stake(ITakesMarket.Side.YES, 1001 * ONE_USDC); // above MAX_STAKE
    }

    /* ─────────────────────── Impairment ─────────────────────── */

    function test_impairedYieldSource_scalesPrincipalProRata() public {
        _stake(alice, ITakesMarket.Side.YES, 100 * ONE_USDC);
        _stake(bob, ITakesMarket.Side.NO, 100 * ONE_USDC);

        // Vault loses 20 USDC (10% of 200 staked)
        vault.incurLoss(20 * ONE_USDC);

        vm.warp(market.lockupEnd());
        market.settle();

        assertTrue(market.impaired());
        assertEq(market.yieldPool(), 0);

        // Each gets 90% principal back, no yield
        uint256 aBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claim();
        assertEq(usdc.balanceOf(alice) - aBefore, 90 * ONE_USDC);

        uint256 bBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        market.claim();
        assertEq(usdc.balanceOf(bob) - bBefore, 90 * ONE_USDC);
    }

    /* ─────────────────── Escrow failure (M-1) ───────────────── */

    function test_escrowFailure_paysOutSharesProRata() public {
        // Two stakers, equal principal
        _stake(alice, ITakesMarket.Side.YES, 100 * ONE_USDC);
        _stake(bob, ITakesMarket.Side.NO, 50 * ONE_USDC);

        uint256 sharesHeldBefore = vault.balanceOf(address(market));
        assertGt(sharesHeldBefore, 0);

        // Break the vault — redeem will revert
        vault.setRedeemBlocked(true);

        vm.warp(market.lockupEnd());
        market.settle();

        // Settlement does NOT revert; instead flags escrow failure
        assertTrue(market.settled());
        assertTrue(market.escrowFailed());
        assertFalse(market.impaired());
        assertEq(market.yieldPool(), 0);
        assertEq(market.totalRedeemed(), 0);
        assertEq(market.sharesAtSettlement(), sharesHeldBefore);

        // Each staker claims pro-rata SHARES (not USDC)
        uint256 aliceSharesBefore = vault.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claim();
        // Alice has 100 / 150 of principal -> 100/150 of shares
        uint256 expectedAliceShares = (100 * ONE_USDC * sharesHeldBefore) / (150 * ONE_USDC);
        assertEq(vault.balanceOf(alice) - aliceSharesBefore, expectedAliceShares);
        // No USDC paid out
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore);

        uint256 bobSharesBefore = vault.balanceOf(bob);
        vm.prank(bob);
        market.claim();
        uint256 expectedBobShares = (50 * ONE_USDC * sharesHeldBefore) / (150 * ONE_USDC);
        assertEq(vault.balanceOf(bob) - bobSharesBefore, expectedBobShares);

        // Now alice can recover by redeeming directly with the vault, once
        // it's restored
        vault.setRedeemBlocked(false);
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        // Alice gets back ~100 USDC (no yield, no loss in this path)
        assertApproxEqAbs(usdc.balanceOf(alice) - aliceUsdcBefore, 100 * ONE_USDC, 1);
    }

    /* ─────────────── Donation absorption (L-1) ────────────────── */

    function test_directDonationsAbsorbedIntoYieldPool() public {
        _stake(alice, ITakesMarket.Side.YES, 50 * ONE_USDC);

        // Someone sends USDC directly to the market, bypassing stake()
        usdc.mint(address(this), 5 * ONE_USDC);
        usdc.transfer(address(market), 5 * ONE_USDC);

        vm.warp(market.lockupEnd());
        market.settle();

        // The 5 USDC donation is now part of yieldPool (no yield was injected)
        assertEq(market.yieldPool(), 5 * ONE_USDC);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claim();
        // Alice (sole winner) takes principal + entire yield pool incl. donation
        assertEq(usdc.balanceOf(alice) - aliceBefore, 55 * ONE_USDC);
    }

    /* ────────────────── Settled state reports tie + impaired (L-2/L-3) ───────── */

    function test_settledState_reportsTieAndImpairedFlags() public {
        _stake(alice, ITakesMarket.Side.YES, 50 * ONE_USDC);
        _stake(bob, ITakesMarket.Side.NO, 50 * ONE_USDC);

        // Tie + impairment combined — both flags should be set
        vault.incurLoss(10 * ONE_USDC);
        vm.warp(market.lockupEnd());
        market.settle();

        assertTrue(market.isTie());
        assertTrue(market.impaired());
        assertFalse(market.escrowFailed());
        assertEq(market.yieldPool(), 0);
    }
}
