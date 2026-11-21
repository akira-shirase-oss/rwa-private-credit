// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.30;

import {Council} from "../src/Council.sol";
import {PoolToken} from "../src/PoolToken.sol";
import {Fixture} from "./Fixture.sol";

/// The documented process: M-of-N distinct approvals, the delay, the grace period, the
/// exact calldata, once only, and a membership change voids what is pending.
contract CouncilTest is Fixture {
    bytes32 internal constant COUNCIL_CODEHASH = 0xca30be8edb5ae4b82eebe2976681f456614eb8bd21544338a27759a4ed2ce6d2;

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
        address[] memory three = new address[](3);
        (three[0], three[1], three[2]) = (m1, m2, m3);
        vm.expectRevert(abi.encodeWithSelector(Council.BadThreshold.selector, 1, 3));
        deployer.council(three, 1, 1 days);
        vm.expectRevert(abi.encodeWithSelector(Council.BadThreshold.selector, 4, 3));
        deployer.council(three, 4, 1 days);
        vm.expectRevert(abi.encodeWithSelector(Council.BadDelay.selector, 1 days - 1));
        deployer.council(three, 2, 1 days - 1);
        vm.expectRevert(abi.encodeWithSelector(Council.BadDelay.selector, 30 days + 1));
        deployer.council(three, 2, 30 days + 1);
        three[1] = m1;
        vm.expectRevert(Council.BadMembers.selector);
        deployer.council(three, 2, 1 days);
        three[1] = address(0);
        vm.expectRevert(Council.BadMembers.selector);
        deployer.council(three, 2, 1 days);
        address[] memory many = new address[](17);
        for (uint256 i = 0; i < 17; ++i) {
            many[i] = address(uint160(i + 1));
        }
        vm.expectRevert(Council.BadMembers.selector);
        deployer.council(many, 2, 1 days);
    }

    /// M == N would let one member veto every change to the council (N - M + 1 = 1) and so
    /// keep itself on it: the threshold is below the member count.
    function test_the_threshold_is_below_the_member_count() public {
        address[] memory three = new address[](3);
        (three[0], three[1], three[2]) = (m1, m2, m3);
        vm.expectRevert(abi.encodeWithSelector(Council.BadThreshold.selector, 3, 3));
        deployer.council(three, 3, 1 days);
        address[] memory two = new address[](2);
        (two[0], two[1]) = (m1, m2);
        vm.expectRevert(abi.encodeWithSelector(Council.BadThreshold.selector, 2, 2));
        deployer.council(two, 2, 1 days);
        bytes memory change = abi.encodeCall(Council.setMembers, (two, 2));
        bytes32 id = _queue(address(council), change);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(Council.BadThreshold.selector, 2, 2));
        vm.prank(m3);
        council.execute(id, change);
        assertEq(council.members().length, 3);
        assertEq(council.threshold(), 2);
        assertEq(council.vetoesNeeded(address(council)), 2);
    }

    /// The council executing `approve` on itself would count as a member's approval.
    function test_the_council_is_never_its_own_member() public {
        address[] memory next = new address[](3);
        (next[0], next[1], next[2]) = (m1, m2, address(council));
        bytes memory change = abi.encodeCall(Council.setMembers, (next, 2));
        bytes32 id = _queue(address(council), change);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(Council.BadMembers.selector);
        vm.prank(m3);
        council.execute(id, change);
        assertFalse(council.isMember(address(council)));
        assertTrue(council.isMember(m3));
        address predicted = vm.computeCreateAddress(address(deployer), vm.getNonce(address(deployer)));
        (next[0], next[1], next[2]) = (m1, m2, predicted);
        vm.expectRevert(Council.BadMembers.selector);
        deployer.council(next, 2, 1 days);
        assertEq(predicted.code.length, 0);
    }

    /// A member that cancels the revocation of a compromised role is removed by the others
    /// (it alone cannot cancel its removal), and the revocation then goes through: two delays.
    function test_a_member_cancelling_a_revocation_is_removed_and_the_revocation_executes() public {
        bytes memory revoke = abi.encodeCall(token.revokeRole, (token.AGENT_ROLE(), agent));
        bytes32 first = _queue(address(token), revoke);
        vm.prank(m3);
        council.cancel(first);
        assertTrue(council.proposal(first).cancelled);
        uint256 started = block.timestamp;

        address replacement = makeAddr("member-4");
        address[] memory next = new address[](3);
        (next[0], next[1], next[2]) = (m1, m2, replacement);
        bytes memory removal = abi.encodeCall(Council.setMembers, (next, 2));
        bytes32 change = _queue(address(council), removal);
        vm.prank(m3);
        council.cancel(change);
        assertFalse(council.proposal(change).cancelled);
        vm.warp(block.timestamp + 1 days);
        vm.prank(m1);
        council.execute(change, removal);
        assertFalse(council.isMember(m3));

        bytes32 second = _queue(address(token), revoke);
        vm.expectRevert(abi.encodeWithSelector(Council.NotMember.selector, m3));
        vm.prank(m3);
        council.cancel(second);
        vm.warp(block.timestamp + 1 days);
        vm.prank(replacement);
        council.execute(second, revoke);
        assertFalse(token.hasRole(token.AGENT_ROLE(), agent));
        assertEq(block.timestamp - started, 2 days);
    }

    /// Governed contracts accept only a council whose runtime code hashes to this. Any edit
    /// of Council.sol (a comment included: the metadata hash is part of the code) or of the
    /// compiler settings changes it; docs/ACCESS_CONTROL.md says how to deploy a matching
    /// council and when to update this value.
    function test_the_council_runtime_hash_is_the_recorded_one() public view {
        assertEq(keccak256(type(Council).runtimeCode), COUNCIL_CODEHASH);
        assertEq(address(council).codehash, COUNCIL_CODEHASH);
    }

    function _queue(address target, bytes memory data) internal returns (bytes32 id) {
        vm.prank(m1);
        id = council.propose(target, data, REASON);
        vm.prank(m2);
        council.approve(id);
    }

    function test_the_council_changes_its_delay_only_through_itself() public {
        _viaCouncil(address(council), abi.encodeCall(Council.setDelay, (3 days)));
        assertEq(council.delay(), 3 days);
        assertEq(council.members().length, 3);
    }
}
