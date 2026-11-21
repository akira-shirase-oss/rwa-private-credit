// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.30;

import {Council} from "../src/Council.sol";
import {PoolToken} from "../src/PoolToken.sol";
import {Fixture} from "./Fixture.sol";

/// The documented process: M-of-N distinct approvals, the delay, the grace period, the
/// exact calldata, once only, and a membership change voids what is pending.
contract CouncilTest is Fixture {
    bytes internal call_;

    function setUp() public override {
        super.setUp();
        call_ = abi.encodeCall(PoolToken.forcedTransfer, (alice, bob, 100));
    }

    function _proposeAndApprove() internal returns (bytes32 id) {
        vm.prank(m1);
        id = council.propose(address(token), call_, REASON);
        vm.prank(m2);
        council.approve(id);
    }

    function test_the_process_executes_once_after_the_delay() public {
        bytes32 id = _proposeAndApprove();
        vm.warp(block.timestamp + 1 days);
        vm.prank(m3);
        council.execute(id, call_);
        assertEq(token.balanceOf(bob), 100);
        assertTrue(council.proposal(id).executed);
    }

    function test_execution_before_the_delay_is_refused() public {
        bytes32 id = _proposeAndApprove();
        uint256 eta = block.timestamp + 1 days;
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(Council.TooEarly.selector, id, eta));
        vm.prank(m1);
        council.execute(id, call_);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_execution_after_the_grace_period_is_refused() public {
        bytes32 id = _proposeAndApprove();
        uint256 deadline = block.timestamp + 1 days + council.GRACE_PERIOD();
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(Council.Expired.selector, id, deadline));
        vm.prank(m1);
        council.execute(id, call_);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_a_single_member_cannot_reach_the_threshold() public {
        vm.prank(m1);
        bytes32 id = council.propose(address(token), call_, REASON);
        vm.expectRevert(abi.encodeWithSelector(Council.AlreadyApproved.selector, id, m1));
        vm.prank(m1);
        council.approve(id);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(Council.NotQueued.selector, id));
        vm.prank(m1);
        council.execute(id, call_);
        assertEq(council.proposal(id).approvals, 1);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_replay_is_refused() public {
        bytes32 id = _proposeAndApprove();
        vm.warp(block.timestamp + 1 days);
        vm.prank(m1);
        council.execute(id, call_);
        vm.expectRevert(abi.encodeWithSelector(Council.AlreadyExecuted.selector, id));
        vm.prank(m1);
        council.execute(id, call_);
        assertEq(token.balanceOf(bob), 100);
    }

    function test_other_calldata_is_refused() public {
        bytes32 id = _proposeAndApprove();
        vm.warp(block.timestamp + 1 days);
        bytes memory other = abi.encodeCall(PoolToken.forcedTransfer, (alice, bob, 1000));
        vm.expectRevert(abi.encodeWithSelector(Council.DataMismatch.selector, id));
        vm.prank(m1);
        council.execute(id, other);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_a_membership_change_voids_pending_proposals() public {
        bytes32 id = _proposeAndApprove();
        address[] memory next = new address[](3);
        (next[0], next[1], next[2]) = (m1, m2, outsider);
        _viaCouncil(address(council), abi.encodeCall(Council.setMembers, (next, 2)));
        assertTrue(council.isMember(outsider));
        assertFalse(council.isMember(m3));
        vm.expectRevert(abi.encodeWithSelector(Council.StaleProposal.selector, id));
        vm.prank(m1);
        council.execute(id, call_);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_a_reverting_call_leaves_the_proposal_executable() public {
        bytes memory bad = abi.encodeCall(PoolToken.forcedTransfer, (alice, outsider, 1));
        vm.prank(m1);
        bytes32 id = council.propose(address(token), bad, REASON);
        vm.prank(m2);
        council.approve(id);
        vm.warp(block.timestamp + 1 days);
        vm.prank(m1);
        (bool ok,) = address(council).call(abi.encodeCall(Council.execute, (id, bad)));
        assertFalse(ok);
        assertFalse(council.proposal(id).executed);
    }

    // ----- stopping a call: revoke before it queues, cancel before it executes -----

    function test_a_member_cancels_a_queued_call_before_execution() public {
        bytes32 id = _proposeAndApprove();
        vm.expectEmit(address(council));
        emit Council.Cancelled(id);
        vm.prank(m3);
        council.cancel(id);
        assertTrue(council.proposal(id).cancelled);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(Council.ProposalCancelled.selector, id));
        vm.prank(m1);
        council.execute(id, call_);
        vm.expectRevert(abi.encodeWithSelector(Council.ProposalCancelled.selector, id));
        vm.prank(m3);
        council.approve(id);
        assertEq(token.balanceOf(alice), 1000);
        assertEq(token.balanceOf(bob), 0);
    }

    /// One member cannot block the council changing itself (removing that member); it
    /// takes N - M + 1 members, the most that could ever refuse to approve.
    function test_a_single_member_cannot_cancel_the_councils_own_change() public {
        bytes memory change = abi.encodeCall(Council.setDelay, (3 days));
        vm.prank(m1);
        bytes32 id = council.propose(address(council), change, REASON);
        vm.prank(m2);
        council.approve(id);
        assertEq(council.vetoesNeeded(address(council)), 2);
        assertEq(council.vetoesNeeded(address(token)), 1);
        vm.prank(m3);
        council.cancel(id);
        vm.expectRevert(abi.encodeWithSelector(Council.AlreadyVetoed.selector, id, m3));
        vm.prank(m3);
        council.cancel(id);
        assertFalse(council.proposal(id).cancelled);
        assertEq(council.proposal(id).vetoes, 1);
        vm.warp(block.timestamp + 1 days);
        vm.prank(m1);
        council.execute(id, change);
        assertEq(council.delay(), 3 days);
    }

    function test_n_minus_m_plus_one_members_cancel_the_councils_own_change() public {
        bytes memory change = abi.encodeCall(Council.setDelay, (3 days));
        vm.prank(m1);
        bytes32 id = council.propose(address(council), change, REASON);
        vm.prank(m2);
        council.approve(id);
        vm.prank(m3);
        council.cancel(id);
        vm.prank(m1);
        council.cancel(id);
        assertTrue(council.proposal(id).cancelled);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(Council.ProposalCancelled.selector, id));
        vm.prank(m2);
        council.execute(id, change);
        assertEq(council.delay(), 1 days);
    }

    function test_a_revoked_approval_does_not_count() public {
        vm.prank(m1);
        bytes32 id = council.propose(address(token), call_, REASON);
        vm.prank(m1);
        council.revokeApproval(id);
        assertFalse(council.hasApproved(id, m1));
        vm.prank(m2);
        council.approve(id);
        assertEq(council.proposal(id).approvals, 1);
        assertEq(council.proposal(id).eta, 0);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(abi.encodeWithSelector(Council.NotQueued.selector, id));
        vm.prank(m2);
        council.execute(id, call_);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_an_approval_is_revoked_only_before_it_queues_and_only_if_given() public {
        bytes32 id = _proposeAndApprove();
        uint64 eta = council.proposal(id).eta;
        vm.expectRevert(abi.encodeWithSelector(Council.AlreadyQueued.selector, id));
        vm.prank(m2);
        council.revokeApproval(id);
        assertEq(council.proposal(id).approvals, 2);
        assertEq(council.proposal(id).eta, eta);
        assertTrue(council.hasApproved(id, m2));
        vm.prank(m1);
        bytes32 other = council.propose(address(token), call_, REASON);
        vm.expectRevert(abi.encodeWithSelector(Council.NotApproved.selector, other, m2));
        vm.prank(m2);
        council.revokeApproval(other);
        assertEq(council.proposal(other).approvals, 1);
    }

    function test_proposals_need_a_contract_target_and_a_reason() public {
        vm.startPrank(m1);
        vm.expectRevert(abi.encodeWithSelector(Council.BadTarget.selector, outsider));
        council.propose(outsider, call_, REASON);
        vm.expectRevert(Council.ReasonRequired.selector);
        council.propose(address(token), call_, 0);
        vm.expectRevert(abi.encodeWithSelector(Council.UnknownProposal.selector, bytes32(uint256(1))));
        council.approve(bytes32(uint256(1)));
        vm.stopPrank();
        assertEq(council.proposalCount(), 0);
    }

    function test_the_council_refuses_weak_or_duplicate_membership() public {
        address[] memory two = new address[](2);
        (two[0], two[1]) = (m1, m2);
        vm.expectRevert(abi.encodeWithSelector(Council.BadThreshold.selector, 1, 2));
        deployer.council(two, 1, 1 days);
        vm.expectRevert(abi.encodeWithSelector(Council.BadThreshold.selector, 3, 2));
        deployer.council(two, 3, 1 days);
        vm.expectRevert(abi.encodeWithSelector(Council.BadDelay.selector, 1 days - 1));
        deployer.council(two, 2, 1 days - 1);
        vm.expectRevert(abi.encodeWithSelector(Council.BadDelay.selector, 30 days + 1));
        deployer.council(two, 2, 30 days + 1);
        two[1] = m1;
        vm.expectRevert(Council.BadMembers.selector);
        deployer.council(two, 2, 1 days);
        two[1] = address(0);
        vm.expectRevert(Council.BadMembers.selector);
        deployer.council(two, 2, 1 days);
        address[] memory many = new address[](17);
        for (uint256 i = 0; i < 17; ++i) {
            many[i] = address(uint160(i + 1));
        }
        vm.expectRevert(Council.BadMembers.selector);
        deployer.council(many, 2, 1 days);
    }

    function test_the_council_changes_its_delay_only_through_itself() public {
        _viaCouncil(address(council), abi.encodeCall(Council.setDelay, (3 days)));
        assertEq(council.delay(), 3 days);
        assertEq(council.members().length, 3);
    }
}
