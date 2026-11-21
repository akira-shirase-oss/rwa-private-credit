// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.30;

/// The governance process for every privileged action that can move a holder's tokens or
/// change a rule: an M-of-N council of distinct members (M >= 2) with a delay. A member
/// proposes a call with a reason code, other members approve it, and once the threshold
/// is reached the call is queued; after the delay, and before the grace period ends, a
/// member executes it exactly once. Any change of membership or threshold invalidates
/// every pending proposal. A member may withdraw its approval until the call queues, and
/// any member may cancel a call before it executes; a call to the council itself needs
/// N - M + 1 members to cancel, so no one member can keep itself on the council. The
/// council administers itself only through its own process.
/// docs/ACCESS_CONTROL.md is the written model.
contract Council {
    uint256 public constant MIN_THRESHOLD = 2;
    uint256 public constant MAX_MEMBERS = 16;
    uint256 public constant MIN_DELAY = 1 days;
    uint256 public constant MAX_DELAY = 30 days;
    /// How long a queued proposal stays executable after its delay.
    uint256 public constant GRACE_PERIOD = 14 days;

    struct Proposal {
        address target;
        uint64 epoch;
        uint64 eta;
        uint8 approvals;
        bool executed;
        bool cancelled;
        uint8 vetoes;
        bytes32 dataHash;
        bytes32 reasonCode;
    }

    address[] private _members;
    mapping(address account => bool) public isMember;
    uint256 public threshold;
    uint256 public delay;
    /// Bumped on every membership or threshold change; a proposal is valid only in its epoch.
    uint64 public epoch;
    uint256 public proposalCount;
    mapping(bytes32 id => Proposal) private _proposals;
    mapping(bytes32 id => mapping(address member => bool)) public hasApproved;
    mapping(bytes32 id => mapping(address member => bool)) public hasVetoed;

    event Proposed(
        bytes32 indexed id, address indexed proposer, address indexed target, bytes data, bytes32 reasonCode
    );
    event Approved(bytes32 indexed id, address indexed member, uint256 approvals);
    event ApprovalRevoked(bytes32 indexed id, address indexed member, uint256 approvals);
    event Queued(bytes32 indexed id, uint256 eta);
    event Vetoed(bytes32 indexed id, address indexed member, uint256 vetoes);
    event Cancelled(bytes32 indexed id);
    event Executed(bytes32 indexed id, address indexed executor, address indexed target, bytes32 reasonCode);
    event MembersChanged(uint64 indexed epoch, address[] members, uint256 threshold);
    event DelayChanged(uint256 delay);

    error NotMember(address caller);
    error NotSelf(address caller);
    error BadMembers();
    error BadThreshold(uint256 threshold, uint256 members);
    error BadDelay(uint256 delay);
    error BadTarget(address target);
    error ReasonRequired();
    error UnknownProposal(bytes32 id);
    error AlreadyExecuted(bytes32 id);
    error StaleProposal(bytes32 id);
    error AlreadyApproved(bytes32 id, address member);
    error NotQueued(bytes32 id);
    error TooEarly(bytes32 id, uint256 eta);
    error Expired(bytes32 id, uint256 deadline);
    error DataMismatch(bytes32 id);
    error ProposalCancelled(bytes32 id);
    error NotApproved(bytes32 id, address member);
    error AlreadyQueued(bytes32 id);
    error AlreadyVetoed(bytes32 id, address member);

    constructor(address[] memory members_, uint256 threshold_, uint256 delay_) {
        _setMembers(members_, threshold_);
        _setDelay(delay_);
    }

    modifier onlyMember() {
        if (!isMember[msg.sender]) revert NotMember(msg.sender);
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf(msg.sender);
        _;
    }

    function members() external view returns (address[] memory) {
        return _members;
    }

    function proposal(bytes32 id) external view returns (Proposal memory) {
        return _proposals[id];
    }

    /// Proposes `target.call(data)`; the proposer's approval counts. `reasonCode` is the
    /// hash of the off-chain record that justifies the action (never personal data).
    function propose(address target, bytes calldata data, bytes32 reasonCode)
        external
        onlyMember // GUARD(council-propose-member)
        returns (bytes32 id)
    {
        if (target.code.length == 0) revert BadTarget(target); // GUARD(council-target-contract)
        if (reasonCode == bytes32(0)) revert ReasonRequired(); // GUARD(council-reason-required)
        uint256 n = ++proposalCount;
        id = keccak256(abi.encode(block.chainid, address(this), n, target, keccak256(data), reasonCode));
        _proposals[id] = Proposal({
            target: target,
            epoch: epoch,
            eta: 0,
            approvals: 0,
            executed: false,
            cancelled: false,
            vetoes: 0,
            dataHash: keccak256(data),
            reasonCode: reasonCode
        });
        emit Proposed(id, msg.sender, target, data, reasonCode);
        _approve(id, msg.sender);
    }

    // GUARD(council-approve-member)
    function approve(bytes32 id) external onlyMember {
        _approve(id, msg.sender);
    }

    /// Withdraws the caller's approval of a proposal that has not yet queued.
    // GUARD(council-revoke-member)
    function revokeApproval(bytes32 id) external onlyMember {
        Proposal storage p = _live(id);
        if (p.eta != 0) revert AlreadyQueued(id); // GUARD(council-revoke-unqueued)
        if (!hasApproved[id][msg.sender]) revert NotApproved(id, msg.sender);
        hasApproved[id][msg.sender] = false;
        uint8 approvals = p.approvals - 1;
        p.approvals = approvals; // GUARD(council-revoke-counts)
        emit ApprovalRevoked(id, msg.sender, approvals);
    }

    /// Records the caller's veto; once `vetoesNeeded(target)` distinct members have vetoed,
    /// the proposal is cancelled and can never be approved or executed.
    // GUARD(council-cancel-member)
    function cancel(bytes32 id) external onlyMember {
        Proposal storage p = _live(id);
        if (hasVetoed[id][msg.sender]) revert AlreadyVetoed(id, msg.sender); // GUARD(council-distinct-vetoes)
        hasVetoed[id][msg.sender] = true;
        uint8 vetoes = p.vetoes + 1;
        p.vetoes = vetoes;
        emit Vetoed(id, msg.sender, vetoes);
        if (vetoes >= vetoesNeeded(p.target)) {
            p.cancelled = true;
            emit Cancelled(id);
        }
    }

    /// One member stops a call to another contract; a call to the council itself (its
    /// membership or delay) takes N - M + 1, the fewest that M approvals cannot outvote.
    function vetoesNeeded(address target) public view returns (uint256) {
        if (target != address(this)) return 1;
        return _members.length - threshold + 1; // GUARD(council-self-veto-quorum)
    }

    /// Executes a queued proposal once its delay has passed. `data` must be the proposed
    /// bytes. A call that reverts leaves the proposal executable until it expires.
    // GUARD(council-execute-member)
    function execute(bytes32 id, bytes calldata data) external onlyMember returns (bytes memory result) {
        Proposal storage p = _live(id);
        if (p.eta == 0) revert NotQueued(id);
        if (block.timestamp < p.eta) revert TooEarly(id, p.eta); // GUARD(council-delay)
        if (block.timestamp > p.eta + GRACE_PERIOD) revert Expired(id, p.eta + GRACE_PERIOD); // GUARD(council-expiry)
        if (keccak256(data) != p.dataHash) revert DataMismatch(id); // GUARD(council-data)
        p.executed = true; // GUARD(council-replay)
        bool ok;
        (ok, result) = p.target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        emit Executed(id, msg.sender, p.target, p.reasonCode);
    }

    // GUARD(council-members-self)
    function setMembers(address[] calldata members_, uint256 threshold_) external onlySelf {
        _setMembers(members_, threshold_);
    }

    // GUARD(council-delay-self)
    function setDelay(uint256 delay_) external onlySelf {
        _setDelay(delay_);
    }

    function _approve(bytes32 id, address member) private {
        Proposal storage p = _live(id);
        if (hasApproved[id][member]) revert AlreadyApproved(id, member); // GUARD(council-distinct)
        hasApproved[id][member] = true;
        uint8 approvals = p.approvals + 1;
        p.approvals = approvals;
        emit Approved(id, member, approvals);
        bool reached = approvals == threshold; // GUARD(council-threshold)
        if (reached) {
            uint256 eta = block.timestamp + delay;
            p.eta = uint64(eta);
            emit Queued(id, eta);
        }
    }

    function _live(bytes32 id) private view returns (Proposal storage p) {
        p = _proposals[id];
        if (p.target == address(0)) revert UnknownProposal(id);
        if (p.executed) revert AlreadyExecuted(id); // GUARD(council-executed-once)
        if (p.cancelled) revert ProposalCancelled(id); // GUARD(council-cancelled)
        if (p.epoch != epoch) revert StaleProposal(id); // GUARD(council-epoch)
    }

    function _setMembers(address[] memory members_, uint256 threshold_) private {
        uint256 count = members_.length;
        if (count == 0 || count > MAX_MEMBERS) revert BadMembers();
        if (threshold_ < MIN_THRESHOLD || threshold_ > count) revert BadThreshold(threshold_, count); // GUARD(council-min-threshold)
        for (uint256 i = 0; i < _members.length; ++i) {
            isMember[_members[i]] = false;
        }
        delete _members;
        for (uint256 i = 0; i < count; ++i) {
            address m = members_[i];
            if (m == address(0) || isMember[m]) revert BadMembers(); // GUARD(council-unique-members)
            isMember[m] = true;
            _members.push(m);
        }
        threshold = threshold_;
        uint64 next = epoch + 1;
        epoch = next;
        emit MembersChanged(next, members_, threshold_);
    }

    function _setDelay(uint256 delay_) private {
        if (delay_ < MIN_DELAY || delay_ > MAX_DELAY) revert BadDelay(delay_); // GUARD(council-min-delay)
        delay = delay_;
        emit DelayChanged(delay_);
    }
}
