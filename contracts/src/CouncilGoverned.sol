// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.30;

interface ICouncilParameters {
    function threshold() external view returns (uint256);
    function delay() external view returns (uint256);
}

/// Roles whose only administrator is an immutable council (docs/ACCESS_CONTROL.md). There
/// is no admin role to hand over: the council grants and revokes every role, and the
/// council is fixed at deployment. A holder may renounce its own role.
abstract contract CouncilGoverned {
    /// The fewest approvals and the shortest delay a council may have (Council enforces
    /// the same bounds; checked here so no contract is ever governed by a single key).
    uint256 internal constant MIN_COUNCIL_THRESHOLD = 2;
    uint256 internal constant MIN_COUNCIL_DELAY = 1 days;

    address public immutable council;
    mapping(bytes32 role => mapping(address account => bool)) private _roles;

    event RoleGranted(bytes32 indexed role, address indexed account);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed by);

    error NotCouncil(address caller);
    error MissingRole(bytes32 role, address caller);
    error CouncilTooWeak(address council);
    error ZeroAddress();

    constructor(address council_) {
        if (council_.code.length == 0) revert CouncilTooWeak(council_); // GUARD(council-is-contract)
        ICouncilParameters c = ICouncilParameters(council_);
        if (c.threshold() < MIN_COUNCIL_THRESHOLD || c.delay() < MIN_COUNCIL_DELAY) revert CouncilTooWeak(council_); // GUARD(council-strength)
        council = council_;
    }

    modifier onlyCouncil() {
        _onlyCouncil();
        _;
    }

    modifier onlyRole(bytes32 role) {
        if (!_roles[role][msg.sender]) revert MissingRole(role, msg.sender);
        _;
    }

    modifier onlyRoleOrCouncil(bytes32 role) {
        _onlyRoleOrCouncil(role);
        _;
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    // GUARD(grant-role)
    function grantRole(bytes32 role, address account) external onlyCouncil {
        if (account == address(0)) revert ZeroAddress();
        if (!_roles[role][account]) {
            _roles[role][account] = true;
            emit RoleGranted(role, account);
        }
    }

    // GUARD(revoke-role)
    function revokeRole(bytes32 role, address account) external onlyCouncil {
        _revoke(role, account);
    }

    /// A role holder gives up its own role; it cannot touch anyone else's. AUTH(self)
    function renounceRole(bytes32 role) external {
        _revoke(role, msg.sender);
    }

    function _revoke(bytes32 role, address account) private {
        if (_roles[role][account]) {
            _roles[role][account] = false;
            emit RoleRevoked(role, account, msg.sender);
        }
    }

    function _onlyCouncil() internal view {
        if (msg.sender != council) revert NotCouncil(msg.sender);
    }

    function _onlyRoleOrCouncil(bytes32 role) internal view {
        if (msg.sender != council && !_roles[role][msg.sender]) revert MissingRole(role, msg.sender);
    }
}
