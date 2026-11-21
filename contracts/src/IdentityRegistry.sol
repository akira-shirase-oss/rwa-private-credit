// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.30;

import {CouncilGoverned} from "./CouncilGoverned.sol";

/// Wallet -> eligibility claims. Only claims and flags live here (invariant 5): an opaque
/// investor id assigned off-chain (never derived from personal data), an ISO-3166 numeric
/// country, an investor type, a KYC expiry and a frozen flag. Contracts that hold tokens
/// (escrows, distributors) are registered like any holder, with investor type `Contract`.
contract IdentityRegistry is CouncilGoverned {
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");

    /// The longest a KYC claim may stay valid when it is set.
    uint256 public constant MAX_KYC_VALIDITY = 3 * 365 days;
    uint16 public constant MAX_COUNTRY = 999;

    enum InvestorType {
        None,
        Retail,
        Professional,
        Institutional,
        Contract
    }

    struct Identity {
        bytes32 investorId;
        uint64 kycExpiry;
        uint16 country;
        InvestorType investorType;
        bool registered;
        bool frozen;
    }

    mapping(address wallet => Identity) private _identities;

    event IdentityRegistered(
        address indexed wallet, bytes32 indexed investorId, uint16 country, InvestorType investorType, uint64 kycExpiry
    );
    event KycUpdated(address indexed wallet, uint64 kycExpiry);
    event CountryUpdated(address indexed wallet, uint16 country);
    event IdentityRemoved(address indexed wallet);
    event InvestorIdSet(address indexed wallet, bytes32 indexed investorId);
    event WalletFrozen(address indexed wallet, bool frozen, address indexed by);

    error AlreadyRegistered(address wallet);
    error NotRegistered(address wallet);
    error BadInvestorId();
    error InvestorIdFixed(address wallet, bytes32 investorId);
    error BadCountry(uint16 country);
    error BadInvestorType();
    error BadKycExpiry(uint64 kycExpiry);

    constructor(address council_) CouncilGoverned(council_) {}

    function register(address wallet, bytes32 investorId, uint16 country, InvestorType investorType, uint64 kycExpiry)
        external
        onlyRole(REGISTRAR_ROLE) // GUARD(registry-register-role)

    {
        if (wallet == address(0)) revert ZeroAddress();
        Identity storage id = _identities[wallet];
        if (id.registered) revert AlreadyRegistered(wallet);
        if (investorId == bytes32(0)) revert BadInvestorId();
        // A wallet's investor id is written once; only the council rebinds it.
        bytes32 bound = id.investorId;
        if (bound != bytes32(0) && bound != investorId) revert InvestorIdFixed(wallet, bound); // GUARD(registry-investor-id-once)
        if (investorType == InvestorType.None) revert BadInvestorType();
        _checkCountry(country);
        _checkKyc(kycExpiry);
        // The frozen flag survives removal and re-registration: only the council clears it.
        id.investorId = investorId;
        id.kycExpiry = kycExpiry;
        id.country = country;
        id.investorType = investorType;
        id.registered = true; // GUARD(registry-keeps-frozen)
        emit IdentityRegistered(wallet, investorId, country, investorType, kycExpiry);
    }

    // GUARD(registry-kyc-role)
    function updateKyc(address wallet, uint64 kycExpiry) external onlyRole(REGISTRAR_ROLE) {
        Identity storage id = _registered(wallet);
        _checkKyc(kycExpiry);
        id.kycExpiry = kycExpiry;
        emit KycUpdated(wallet, kycExpiry);
    }

    // GUARD(registry-country-role)
    function updateCountry(address wallet, uint16 country) external onlyRole(REGISTRAR_ROLE) {
        Identity storage id = _registered(wallet);
        _checkCountry(country);
        id.country = country;
        emit CountryUpdated(wallet, country);
    }

    /// Removes the wallet's eligibility. The investor id stays, so the council can still
    /// recover the wallet's tokens to a new wallet of the same investor.
    // GUARD(registry-remove-role)
    function remove(address wallet) external onlyRole(REGISTRAR_ROLE) {
        Identity storage id = _registered(wallet);
        id.registered = false;
        id.kycExpiry = 0;
        emit IdentityRemoved(wallet);
    }

    /// Rebinds a wallet to another investor id (a registrar's mistake); the council's alone.
    // GUARD(registry-investor-id-council)
    function setInvestorId(address wallet, bytes32 investorId) external onlyCouncil {
        if (wallet == address(0)) revert ZeroAddress();
        if (investorId == bytes32(0)) revert BadInvestorId();
        _identities[wallet].investorId = investorId;
        emit InvestorIdSet(wallet, investorId);
    }

    /// Freezing protects, so an agent may do it at once; unfreezing is the council's.
    // GUARD(registry-freeze-role)
    function freeze(address wallet) external onlyRoleOrCouncil(AGENT_ROLE) {
        _identities[wallet].frozen = true;
        emit WalletFrozen(wallet, true, msg.sender);
    }

    // GUARD(registry-unfreeze-council)
    function unfreeze(address wallet) external onlyCouncil {
        _identities[wallet].frozen = false;
        emit WalletFrozen(wallet, false, msg.sender);
    }

    function identityOf(address wallet) external view returns (Identity memory) {
        return _identities[wallet];
    }

    /// What the compliance module reads, in one call.
    function eligibility(address wallet)
        external
        view
        returns (bool registered, uint64 kycExpiry, uint16 country, bool frozen)
    {
        Identity storage id = _identities[wallet];
        return (id.registered, id.kycExpiry, id.country, id.frozen);
    }

    function investorIdOf(address wallet) external view returns (bytes32) {
        return _identities[wallet].investorId;
    }

    /// Registered with an unexpired KYC claim (frozen is a separate flag).
    function isVerified(address wallet) external view returns (bool) {
        Identity storage id = _identities[wallet];
        return id.registered && id.kycExpiry > block.timestamp;
    }

    function _registered(address wallet) private view returns (Identity storage id) {
        id = _identities[wallet];
        if (!id.registered) revert NotRegistered(wallet);
    }

    function _checkCountry(uint16 country) private pure {
        if (country == 0 || country > MAX_COUNTRY) revert BadCountry(country);
    }

    function _checkKyc(uint64 kycExpiry) private view {
        if (kycExpiry <= block.timestamp || kycExpiry > block.timestamp + MAX_KYC_VALIDITY) {
            revert BadKycExpiry(kycExpiry); // GUARD(registry-kyc-bound)
        }
    }
}
