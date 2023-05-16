// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.19 <0.9.0;

import { Broker, Lockup, LockupDynamic } from "src/types/DataTypes.sol";

import { Withdraw_Fuzz_Test } from "../../lockup/withdraw/withdraw.t.sol";
import { Dynamic_Fuzz_Test } from "../Dynamic.t.sol";

/// @dev This contract complements the tests in {Withdraw_Fuzz_Test} by testing the withdraw function against
/// streams created with fuzzed segments.
contract Withdraw_Dynamic_Fuzz_Test is Dynamic_Fuzz_Test, Withdraw_Fuzz_Test {
    function setUp() public virtual override(Dynamic_Fuzz_Test, Withdraw_Fuzz_Test) {
        Dynamic_Fuzz_Test.setUp();
        Withdraw_Fuzz_Test.setUp();
    }

    struct Params {
        LockupDynamic.Segment[] segments;
        uint256 timeWarp;
        address to;
    }

    struct Vars {
        Lockup.Status actualStatus;
        uint256 actualWithdrawnAmount;
        Lockup.CreateAmounts createAmounts;
        Lockup.Status expectedStatus;
        uint256 expectedWithdrawnAmount;
        bool isDepleted;
        bool isSettled;
        address funder;
        uint256 streamId;
        uint128 totalAmount;
        uint40 totalDuration;
        uint128 withdrawAmount;
        uint128 withdrawableAmount;
    }

    function testFuzz_Withdraw_SegmentFuzing(Params memory params)
        external
        whenNotDelegateCalled
        whenNotNull
        whenCallerAuthorized
        whenToNonZeroAddress
        whenWithdrawAmountNotZero
        whenWithdrawAmountNotGreaterThanWithdrawableAmount
    {
        vm.assume(params.segments.length != 0);
        vm.assume(params.to != address(0));

        // Make the sender the stream's funder (recall that the sender is the default caller).
        Vars memory vars;
        vars.funder = users.sender;

        // Fuzz the segment milestones.
        fuzzSegmentMilestones(params.segments, defaults.START_TIME());

        // Fuzz the segment amounts.
        (vars.totalAmount, vars.createAmounts) = fuzzDynamicStreamAmounts(params.segments);

        // Bound the time warp.
        vars.totalDuration = params.segments[params.segments.length - 1].milestone - defaults.START_TIME();
        params.timeWarp = _bound(params.timeWarp, 1 seconds, vars.totalDuration + 100 seconds);

        // Mint enough assets to the funder.
        deal({ token: address(dai), to: vars.funder, give: vars.totalAmount });

        // Make the sender the caller.
        changePrank({ msgSender: users.sender });

        // Create the stream with the fuzzed segments.
        LockupDynamic.CreateWithMilestones memory createParams = defaults.createWithMilestones();
        createParams.totalAmount = vars.totalAmount;
        createParams.segments = params.segments;

        vars.streamId = dynamic.createWithMilestones(createParams);

        // Simulate the passage of time.
        vm.warp({ timestamp: defaults.START_TIME() + params.timeWarp });

        // Query the withdrawable amount.
        vars.withdrawableAmount = dynamic.withdrawableAmountOf(vars.streamId);

        // Halt the test if the withdraw amount is zero.
        if (vars.withdrawableAmount == 0) {
            return;
        }

        // Bound the withdraw amount.
        vars.withdrawAmount = boundUint128(vars.withdrawAmount, 1, vars.withdrawableAmount);

        // Expect the assets to be transferred to the fuzzed `to` address.
        expectCallToTransfer({ to: params.to, amount: vars.withdrawAmount });

        // Expect a {WithdrawFromLockupStream} event to be emitted.
        vm.expectEmit({ emitter: address(dynamic) });
        emit WithdrawFromLockupStream({ streamId: vars.streamId, to: params.to, amount: vars.withdrawAmount });

        // Make the recipient the caller.
        changePrank({ msgSender: users.recipient });

        // Make the withdrawal.
        dynamic.withdraw({ streamId: vars.streamId, to: params.to, amount: vars.withdrawAmount });

        // Check if the stream is depleted or settled. It is possible for the stream to be just settled
        // and not depleted because the withdraw amount is fuzzed.
        vars.isDepleted = vars.withdrawAmount == vars.createAmounts.deposit;
        vars.isSettled = dynamic.refundableAmountOf(vars.streamId) == 0;

        // Assert that the stream's status is correct.
        vars.actualStatus = dynamic.statusOf(vars.streamId);
        if (vars.isDepleted) {
            vars.expectedStatus = Lockup.Status.DEPLETED;
        } else if (vars.isSettled) {
            vars.expectedStatus = Lockup.Status.SETTLED;
        } else {
            vars.expectedStatus = Lockup.Status.STREAMING;
        }
        assertEq(vars.actualStatus, vars.expectedStatus);

        // Assert that the withdrawn amount has been updated.
        vars.actualWithdrawnAmount = dynamic.getWithdrawnAmount(vars.streamId);
        vars.expectedWithdrawnAmount = vars.withdrawAmount;
        assertEq(vars.actualWithdrawnAmount, vars.expectedWithdrawnAmount, "withdrawnAmount");
    }
}
