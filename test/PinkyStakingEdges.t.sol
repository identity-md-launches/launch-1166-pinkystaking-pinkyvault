// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {PinkyStaking} from "../src/PinkyStaking.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @notice The staking contract at its edges: zero, one wei, a stake of the whole supply, a
/// restretched stream, a staker who was not there, and the idle-stream rule the audit introduced.
contract PinkyStakingEdgesTest is Test {
    uint256 constant DURATION = 7 days;
    uint256 constant SUPPLY = 1_000_000_000 ether;

    MockERC20 imd;
    MockERC20 pinky;
    PinkyStaking staking;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.warp(1_790_000_000);
        imd = new MockERC20("Identity.md", "IMD");
        pinky = new MockERC20("Pinky", "PINKY");
        staking = new PinkyStaking(address(pinky), address(imd));
        pinky.mint(alice, SUPPLY);
        pinky.mint(bob, 100 ether);
        vm.prank(alice);
        pinky.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        pinky.approve(address(staking), type(uint256).max);
        imd.mint(address(this), 1_000_000 ether);
        imd.approve(address(staking), type(uint256).max);
    }

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        staking.stake(amount);
    }

    function _unstake(address who, uint256 amount) internal {
        vm.prank(who);
        staking.unstake(amount);
    }

    function _claim(address who) internal {
        vm.prank(who);
        staking.claim();
    }

    // ───────────────────────── refusals ─────────────────────────

    function test_ZeroAmountsAreRefused() public {
        vm.startPrank(alice);
        vm.expectRevert(PinkyStaking.ZeroAmount.selector);
        staking.stake(0);
        vm.expectRevert(PinkyStaking.ZeroAmount.selector);
        staking.unstake(0);
        vm.expectRevert(PinkyStaking.ZeroAmount.selector);
        staking.claim();
        vm.stopPrank();
    }

    function test_NobodyUnstakesMoreThanTheyStaked() public {
        _stake(alice, 10 ether);
        _stake(bob, 5 ether);
        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError);
        staking.unstake(5 ether + 1);
        vm.prank(carol);
        vm.expectRevert(stdError.arithmeticError);
        staking.unstake(1);
        _unstake(bob, 5 ether);
        assertEq(pinky.balanceOf(bob), 100 ether);
        assertEq(staking.totalStaked(), 10 ether);
    }

    function test_StakeNeedsAnAllowance() public {
        pinky.mint(carol, 1 ether);
        vm.prank(carol);
        vm.expectRevert();
        staking.stake(1 ether);
        assertEq(staking.totalStaked(), 0);
    }

    function test_NotifyNeedsAnAllowanceAndAcceptsExactlyTheFloor() public {
        _stake(alice, 1 ether);
        address poor = makeAddr("poor");
        imd.mint(poor, 1 ether);
        vm.prank(poor);
        vm.expectRevert();
        staking.notify(1 ether);

        uint256 floor_ = staking.MIN_REWARD();
        vm.expectRevert(PinkyStaking.RewardTooSmall.selector);
        staking.notify(floor_ - 1);
        vm.expectEmit(true, false, false, true, address(staking));
        emit PinkyStaking.Notified(address(this), floor_, vm.getBlockTimestamp() + DURATION);
        staking.notify(floor_);
        assertEq(staking.rewardRate(), floor_ / DURATION);
        assertEq(staking.periodFinish(), vm.getBlockTimestamp() + DURATION);
        assertEq(staking.lastUpdate(), vm.getBlockTimestamp());
    }

    function test_NotifyIsRefusedWhileNobodyIsStaked() public {
        _stake(alice, 1 ether);
        _unstake(alice, 1 ether);
        vm.expectRevert(PinkyStaking.NoStakers.selector);
        staking.notify(1 ether);
        assertEq(imd.balanceOf(address(staking)), 0);
    }

    // ───────────────────────── the stream ─────────────────────────

    function test_StreamIsLinearInTime() public {
        _stake(alice, 1 ether);
        staking.notify(7 ether);
        for (uint256 day = 1; day <= 7; ++day) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            assertApproxEqAbs(staking.earned(alice), day * 1 ether, 1e7);
        }
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertApproxEqAbs(staking.earned(alice), 7 ether, 1e7, "nothing accrues after the period");
    }

    function test_AStakerWhoArrivesLateEarnsOnlyFromThen() public {
        _stake(alice, 1 ether);
        staking.notify(7 ether);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        _stake(bob, 1 ether);
        assertEq(staking.earned(bob), 0);
        vm.warp(vm.getBlockTimestamp() + 4 days);
        assertApproxEqAbs(staking.earned(alice), 5 ether, 1e7);
        assertApproxEqAbs(staking.earned(bob), 2 ether, 1e7);
    }

    function test_ANotifyMidStreamRestretchesWhatIsLeft() public {
        _stake(alice, 1 ether);
        staking.notify(7 ether);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        uint256 remaining = (staking.periodFinish() - vm.getBlockTimestamp()) * staking.rewardRate();
        staking.notify(1 ether);
        assertEq(staking.rewardRate(), (1 ether + remaining) / DURATION);
        assertEq(staking.periodFinish(), vm.getBlockTimestamp() + DURATION);
        vm.warp(vm.getBlockTimestamp() + DURATION);
        assertApproxEqAbs(staking.earned(alice), 8 ether, 1e7);
    }

    function test_AFlashStakeInTheSameBlockEarnsNothing() public {
        _stake(alice, 1 ether);
        staking.notify(7 ether);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        _stake(bob, 100 ether);
        assertEq(staking.earned(bob), 0);
        vm.prank(bob);
        vm.expectRevert(PinkyStaking.ZeroAmount.selector);
        staking.claim();
        _unstake(bob, 100 ether);
        assertEq(staking.earned(bob), 0);
        assertApproxEqAbs(staking.earned(alice), 3 ether, 1e7);
    }

    /// @dev The documented rule: stream time that passes with nobody staked is credited to the
    /// next staker. That includes a one-wei staker in the same transaction, which is the price
    /// of not stranding the IMD; it is noted as a finding, not a defect, for the reviewer.
    function test_TheIdleStreamGoesToTheNextStakerAtOnce() public {
        _stake(alice, 1 ether);
        staking.notify(7 ether);
        _unstake(alice, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        pinky.mint(carol, 1);
        vm.startPrank(carol);
        pinky.approve(address(staking), 1);
        staking.stake(1);
        assertApproxEqAbs(staking.earned(carol), 2 ether, 1e7, "two idle days land on the first staker back");
        staking.claim();
        staking.unstake(1);
        vm.stopPrank();
        assertApproxEqAbs(imd.balanceOf(carol), 2 ether, 1e7);
        assertEq(staking.earned(alice), 0);
    }

    function test_RewardsSurviveAFullUnstake() public {
        _stake(alice, 1 ether);
        staking.notify(7 ether);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        _unstake(alice, 1 ether);
        uint256 owed = staking.earned(alice);
        assertApproxEqAbs(owed, 2 ether, 1e7);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertEq(staking.earned(alice), owed, "unstaked, the owed amount is frozen");
        vm.expectEmit(true, false, false, true, address(staking));
        emit PinkyStaking.Claimed(alice, owed);
        _claim(alice);
        assertEq(imd.balanceOf(alice), owed);
        assertEq(staking.earned(alice), 0);
        assertEq(staking.rewards(alice), 0);
    }

    function test_ClaimPaysExactlyWhatWasEarnedAndNoMore() public {
        _stake(alice, 3 ether);
        _stake(bob, 1 ether);
        staking.notify(4 ether);
        vm.warp(vm.getBlockTimestamp() + DURATION);
        uint256 a = staking.earned(alice);
        uint256 b = staking.earned(bob);
        _claim(alice);
        _claim(bob);
        assertEq(imd.balanceOf(alice), a);
        assertEq(imd.balanceOf(bob), b);
        assertLe(a + b, 4 ether);
        assertGe(a + b + DURATION + 10, 4 ether, "only truncation dust stays behind");
        vm.prank(alice);
        vm.expectRevert(PinkyStaking.ZeroAmount.selector);
        staking.claim();
    }

    function test_TheWholeSupplyCanBeStakedWithoutOverflow() public {
        _stake(alice, SUPPLY);
        staking.notify(1_000_000 ether);
        vm.warp(vm.getBlockTimestamp() + DURATION);
        uint256 earned = staking.earned(alice);
        assertLe(earned, 1_000_000 ether);
        assertGe(earned + DURATION + 1e9, 1_000_000 ether);
        _claim(alice);
        _unstake(alice, SUPPLY);
        assertEq(pinky.balanceOf(alice), SUPPLY);
        assertEq(staking.totalStaked(), 0);
    }

    function test_OneWeiStakeBesideTheWholeSupplyRoundsToZeroNotUp() public {
        _stake(alice, SUPPLY);
        pinky.mint(carol, 1);
        vm.startPrank(carol);
        pinky.approve(address(staking), 1);
        staking.stake(1);
        vm.stopPrank();
        staking.notify(1 ether);
        vm.warp(vm.getBlockTimestamp() + DURATION);
        assertEq(staking.earned(carol), 0);
        assertLe(staking.earned(alice) + staking.earned(carol), 1 ether);
    }

    function test_PinkyNeverLeavesExceptByUnstake() public {
        _stake(alice, 10 ether);
        staking.notify(1 ether);
        vm.warp(vm.getBlockTimestamp() + DURATION);
        _claim(alice);
        assertEq(pinky.balanceOf(address(staking)), 10 ether);
        (bool ok,) = address(staking).call(abi.encodeWithSignature("recover(address,uint256)", pinky, 10 ether));
        assertFalse(ok);
        (ok,) = address(staking).call(abi.encodeWithSignature("withdraw(address,address,uint256)", pinky, alice, 1));
        assertFalse(ok);
        assertEq(pinky.balanceOf(address(staking)), 10 ether);
    }

    // ───────────────────────── fuzz ─────────────────────────

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_StreamIsSharedProRataAtEveryMoment(uint256 a, uint256 b, uint256 reward, uint256 t) public {
        a = bound(a, 1 ether, SUPPLY / 2);
        b = bound(b, 1 ether, 100 ether);
        reward = bound(reward, staking.MIN_REWARD(), 1_000_000 ether);
        t = bound(t, 0, 2 * DURATION);
        _stake(alice, a);
        _stake(bob, b);
        staking.notify(reward);
        vm.warp(vm.getBlockTimestamp() + t);
        uint256 elapsed = t > DURATION ? DURATION : t;
        uint256 streamed = staking.rewardRate() * elapsed;
        uint256 ea = staking.earned(alice);
        uint256 eb = staking.earned(bob);
        assertLe(ea + eb, streamed, "nobody earns ahead of the stream");
        // Rounding: one unit of rewardPerToken is (a + b) / 1e18 wei, plus one wei per account.
        assertGe(ea + eb + (a + b) / 1e18 + 2, streamed, "the stream is not lost");
        // Pro rata within the same rounding.
        assertApproxEqAbs(ea * b, eb * a, (a + b) * (a + b) / 1e18 + a + b);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_NoSequenceOfNotifiesPaysOutMoreThanWasPutIn(uint256 r1, uint256 r2, uint256 gap, uint256 split)
        public
    {
        r1 = bound(r1, staking.MIN_REWARD(), 1_000 ether);
        r2 = bound(r2, staking.MIN_REWARD(), 1_000 ether);
        gap = bound(gap, 0, 2 * DURATION);
        split = bound(split, 1, 100 ether);
        _stake(alice, 1 ether);
        _stake(bob, split);
        staking.notify(r1);
        vm.warp(vm.getBlockTimestamp() + gap);
        staking.notify(r2);
        vm.warp(vm.getBlockTimestamp() + DURATION);
        if (staking.earned(alice) != 0) _claim(alice);
        if (staking.earned(bob) != 0) _claim(bob);
        assertLe(imd.balanceOf(alice) + imd.balanceOf(bob), r1 + r2);
        assertGe(imd.balanceOf(alice) + imd.balanceOf(bob) + 2 * DURATION + 1e6, r1 + r2);
    }
}
