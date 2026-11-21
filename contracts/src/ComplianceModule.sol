// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.30;

import {CouncilGoverned} from "./CouncilGoverned.sol";
import {IdentityRegistry} from "./IdentityRegistry.sol";
import {Refusal} from "./Refusal.sol";

/// The transfer rules, as one pure decision over the registry and the token's figures:
/// both parties registered, KYC unexpired, not frozen, country allowed; the lock-up; the
/// maximum number of holders; the minimum holding. It holds no balances and changes no
/// state on a transfer; every parameter change is the council's (timelocked).
contract ComplianceModule is CouncilGoverned {
    /// Lock-up end and similar timestamps may not be set further ahead than this.
    uint256 public constant MAX_LOCKUP = 5 * 365 days;

    IdentityRegistry public immutable registry;
    /// The token's decimals; the minimum holding is at least one whole token, 10 ** decimals.
    uint8 public immutable decimals;
    uint256 public immutable minHoldingFloor;
    uint8 public constant MAX_DECIMALS = 18;

    mapping(uint16 country => bool) public countryAllowed;
    uint256 public maxHolders;
    uint256 public minHolding;
    uint64 public lockupEnd;

    struct Rules {
        uint16[] allowedCountries;
        uint256 maxHolders;
        uint256 minHolding;
        uint64 lockupEnd;
        uint8 decimals;
    }

    event CountryAllowed(uint16 indexed country, bool allowed);
    event MaxHoldersSet(uint256 maxHolders);
    event MinHoldingSet(uint256 minHolding);
    event LockupEndSet(uint64 lockupEnd);

    error BadCountry(uint16 country);
    error BadMaxHolders(uint256 maxHolders);
    error BadLockupEnd(uint64 lockupEnd);
    error BadMinHolding(uint256 minHolding);
    error BadDecimals(uint8 decimals);

    constructor(address council_, IdentityRegistry registry_, Rules memory rules) CouncilGoverned(council_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
        if (rules.decimals > MAX_DECIMALS) revert BadDecimals(rules.decimals);
        decimals = rules.decimals;
        uint256 floor = 10 ** rules.decimals;
        minHoldingFloor = floor;
        for (uint256 i = 0; i < rules.allowedCountries.length; ++i) {
            _setCountry(rules.allowedCountries[i], true);
        }
        _setMaxHolders(rules.maxHolders);
        _setMinHolding(rules.minHolding, floor);
        _setLockupEnd(rules.lockupEnd);
    }

    // GUARD(compliance-country-council)
    function setCountryAllowed(uint16 country, bool allowed) external onlyCouncil {
        _setCountry(country, allowed);
    }

    // GUARD(compliance-max-holders-council)
    function setMaxHolders(uint256 maxHolders_) external onlyCouncil {
        _setMaxHolders(maxHolders_);
    }

    // GUARD(compliance-min-holding-council)
    function setMinHolding(uint256 minHolding_) external onlyCouncil {
        _setMinHolding(minHolding_, minHoldingFloor);
    }

    // GUARD(compliance-lockup-council)
    function setLockupEnd(uint64 lockupEnd_) external onlyCouncil {
        _setLockupEnd(lockupEnd_);
    }

    /// The per-party rules (no amounts): registered, KYC unexpired, not frozen, country
    /// allowed. `sending` picks the sender's or the receiver's refusal code.
    function partyRefusal(address account, bool sending) public view returns (Refusal) {
        (bool registered, uint64 kycExpiry, uint16 country, bool frozen) = registry.eligibility(account);
        if (!registered) return sending ? Refusal.SenderNotRegistered : Refusal.ReceiverNotRegistered; // GUARD(sender-registered) GUARD(receiver-registered)
        if (kycExpiry <= block.timestamp) return sending ? Refusal.SenderKycExpired : Refusal.ReceiverKycExpired; // GUARD(sender-kyc) GUARD(receiver-kyc)
        if (frozen) return sending ? Refusal.SenderFrozen : Refusal.ReceiverFrozen; // GUARD(sender-frozen) GUARD(receiver-frozen)
        if (!countryAllowed[country]) {
            return sending ? Refusal.SenderCountryNotAllowed : Refusal.ReceiverCountryNotAllowed; // GUARD(sender-country) GUARD(receiver-country)
        }
        return Refusal.None;
    }

    /// The decision for one balance move, given the figures after it. `from == 0` is a
    /// mint. A forced move (council) skips the sender's rules, never the receiver's.
    function transferRefusal(
        address from,
        address to,
        uint256 fromAfter,
        uint256 toAfter,
        uint256 holdersAfter,
        bool newHolder,
        bool forced
    ) external view returns (Refusal r) {
        if (from != address(0) && !forced) {
            r = partyRefusal(from, true); // GUARD(sender-checked)
            if (r != Refusal.None) return r;
            if (block.timestamp < lockupEnd) return Refusal.LockUp; // GUARD(lockup)
            if (fromAfter != 0 && fromAfter < minHolding) return Refusal.SenderBelowMinimumHolding; // GUARD(sender-minimum)
        }
        r = partyRefusal(to, false); // GUARD(receiver-checked) GUARD(forced-receiver-checked) GUARD(mint-receiver-checked)
        if (r != Refusal.None) return r;
        if (newHolder && holdersAfter > maxHolders) return Refusal.MaxHolders; // GUARD(max-holders)
        if (toAfter != 0 && toAfter < minHolding) return Refusal.ReceiverBelowMinimumHolding; // GUARD(receiver-minimum)
        return Refusal.None;
    }

    function _setCountry(uint16 country, bool allowed) private {
        if (country == 0 || country > 999) revert BadCountry(country);
        countryAllowed[country] = allowed;
        emit CountryAllowed(country, allowed);
    }

    function _setMaxHolders(uint256 maxHolders_) private {
        if (maxHolders_ == 0) revert BadMaxHolders(maxHolders_);
        maxHolders = maxHolders_;
        emit MaxHoldersSet(maxHolders_);
    }

    /// At least one whole token. A holder slot is taken only by a balance of at least the
    /// minimum, so filling F free slots takes at least F x minHolding (>= F whole tokens),
    /// each part in the wallet of a separately registered investor.
    function _setMinHolding(uint256 minHolding_, uint256 floor) private {
        if (minHolding_ < floor) revert BadMinHolding(minHolding_); // GUARD(min-holding-floor)
        minHolding = minHolding_;
        emit MinHoldingSet(minHolding_);
    }

    function _setLockupEnd(uint64 lockupEnd_) private {
        if (lockupEnd_ > block.timestamp + MAX_LOCKUP) revert BadLockupEnd(lockupEnd_);
        lockupEnd = lockupEnd_;
        emit LockupEndSet(lockupEnd_);
    }
}
