// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.30;

import {ComplianceModule} from "../src/ComplianceModule.sol";
import {Council} from "../src/Council.sol";
import {CouncilGoverned} from "../src/CouncilGoverned.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {PoolToken} from "../src/PoolToken.sol";
import {Refusal} from "../src/Refusal.sol";
import {Fixture} from "./Fixture.sol";

contract WeakCouncil {
    uint256 public threshold;
    uint256 public delay;

    constructor(uint256 threshold_, uint256 delay_) {
        (threshold, delay) = (threshold_, delay_);
    }
}

/// END_GOAL case 9: every privileged entry point refuses every caller without the right,
/// with its own error, and the stored state re-read afterwards is unchanged. The callers
/// tried include a single council member, the other roles and a holder; only the council
/// contract (the M-of-N, delayed process) or the named role gets through.
/// A modified Council: the same parameters, one extra function.
contract ForkedCouncil is Council {
    constructor(address[] memory members_) Council(members_, 2, 1 days) {}

    function extra() external pure returns (uint256) {
        return 1;
    }
}

contract RolesTest is Fixture {
    address[] internal callers;

    function setUp() public override {
        super.setUp();
        callers = [outsider, alice, m1, m2, m3, registrar, agent, minter];
    }

    /// Everything a privileged call could change, hashed.
    function _fingerprint() internal view returns (bytes32) {
        address[5] memory who = [alice, bob, carol, outsider, minter];
        bytes memory state;
        for (uint256 i = 0; i < who.length; ++i) {
            state = abi.encode(
                state,
                token.balanceOf(who[i]),
                token.getFrozenTokens(who[i]),
                registry.identityOf(who[i]),
                token.hasRole(token.MINTER_ROLE(), who[i]),
                token.hasRole(token.AGENT_ROLE(), who[i]),
                registry.hasRole(registry.REGISTRAR_ROLE(), who[i]),
                registry.hasRole(registry.AGENT_ROLE(), who[i])
            );
        }
        state = abi.encode(
            state,
            token.totalSupply(),
            token.paused(),
            token.holderCount(),
            compliance.countryAllowed(CA),
            compliance.countryAllowed(BLOCKED),
            compliance.maxHolders(),
            compliance.minHolding(),
            compliance.lockupEnd()
        );
        return keccak256(
            abi.encode(
                state, council.members(), council.threshold(), council.delay(), council.epoch(), council.proposalCount()
            )
        );
    }

    enum Gate {
        Council,
        Role,
        RoleOrCouncil,
        Member,
        Self
    }

    /// Calls `target` with `data` from every caller not allowed through `gate` and checks
    /// the exact refusal and that nothing changed.
    function _refusedForAll(address target, bytes memory data, Gate gate, bytes32 role, address[] memory allowed)
        internal
    {
        uint256 tried;
        for (uint256 i = 0; i < callers.length; ++i) {
            address caller = callers[i];
            if (_contains(allowed, caller)) continue;
            bytes memory err;
            if (gate == Gate.Council) err = abi.encodeWithSelector(CouncilGoverned.NotCouncil.selector, caller);
            else if (gate == Gate.Member) err = abi.encodeWithSelector(Council.NotMember.selector, caller);
            else if (gate == Gate.Self) err = abi.encodeWithSelector(Council.NotSelf.selector, caller);
            else err = abi.encodeWithSelector(CouncilGoverned.MissingRole.selector, role, caller);
            bytes32 before = _fingerprint();
            vm.prank(caller);
            (bool ok, bytes memory ret) = target.call(data);
            assertFalse(ok, "an unauthorised caller got through");
            assertEq(ret, err, "refused with the wrong error");
            assertEq(_fingerprint(), before, "a refused call changed stored state");
            ++tried;
        }
        assertGt(tried, 0);
    }

    function _contains(address[] memory list, address a) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _one(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _members() internal view returns (address[] memory l) {
        l = new address[](3);
        (l[0], l[1], l[2]) = (m1, m2, m3);
    }

    // ----- role administration (registry, compliance, token: the council only) -----

    function test_unauthorised_grant_role_refused() public {
        bytes memory onRegistry = abi.encodeCall(CouncilGoverned.grantRole, (keccak256("REGISTRAR_ROLE"), outsider));
        bytes memory onToken = abi.encodeCall(CouncilGoverned.grantRole, (keccak256("MINTER_ROLE"), outsider));
        _refusedForAll(address(registry), onRegistry, Gate.Council, 0, _none());
        _refusedForAll(address(token), onToken, Gate.Council, 0, _none());
        _refusedForAll(address(compliance), onToken, Gate.Council, 0, _none());
    }

    function test_unauthorised_revoke_role_refused() public {
        bytes memory onRegistry = abi.encodeCall(CouncilGoverned.revokeRole, (keccak256("REGISTRAR_ROLE"), registrar));
        bytes memory onToken = abi.encodeCall(CouncilGoverned.revokeRole, (keccak256("MINTER_ROLE"), minter));
        _refusedForAll(address(registry), onRegistry, Gate.Council, 0, _none());
        _refusedForAll(address(token), onToken, Gate.Council, 0, _none());
    }

    function test_renounce_role_touches_only_the_callers_own_role() public {
        bytes32 role = token.MINTER_ROLE();
        vm.prank(outsider);
        token.renounceRole(role);
        assertTrue(token.hasRole(role, minter));
        vm.prank(minter);
        token.renounceRole(role);
        assertFalse(token.hasRole(role, minter));
    }

    function test_roles_are_granted_and_revoked_through_the_council_process() public {
        bytes32 role = token.MINTER_ROLE();
        _viaCouncil(address(token), abi.encodeCall(CouncilGoverned.grantRole, (role, outsider)));
        assertTrue(token.hasRole(role, outsider));
        _viaCouncil(address(token), abi.encodeCall(CouncilGoverned.revokeRole, (role, outsider)));
        assertFalse(token.hasRole(role, outsider));
    }

    // ----- registry -----

    function test_unauthorised_register_refused() public {
        bytes memory data = abi.encodeCall(
            IdentityRegistry.register,
            (outsider, keccak256("x"), CA, IdentityRegistry.InvestorType.Retail, uint64(START + 1 days))
        );
        _refusedForAll(address(registry), data, Gate.Role, registry.REGISTRAR_ROLE(), _one(registrar));
    }

    function test_unauthorised_update_kyc_refused() public {
        bytes memory data = abi.encodeCall(IdentityRegistry.updateKyc, (alice, uint64(START + 2 days)));
        _refusedForAll(address(registry), data, Gate.Role, registry.REGISTRAR_ROLE(), _one(registrar));
    }

    function test_unauthorised_update_country_refused() public {
        bytes memory data = abi.encodeCall(IdentityRegistry.updateCountry, (alice, US));
        _refusedForAll(address(registry), data, Gate.Role, registry.REGISTRAR_ROLE(), _one(registrar));
    }

    function test_unauthorised_remove_refused() public {
        bytes memory data = abi.encodeCall(IdentityRegistry.remove, (alice));
        _refusedForAll(address(registry), data, Gate.Role, registry.REGISTRAR_ROLE(), _one(registrar));
    }

    function test_unauthorised_freeze_refused() public {
        bytes memory data = abi.encodeCall(IdentityRegistry.freeze, (alice));
        _refusedForAll(address(registry), data, Gate.RoleOrCouncil, registry.AGENT_ROLE(), _one(agent));
    }

    function test_unauthorised_unfreeze_refused() public {
        vm.prank(agent);
        registry.freeze(alice);
        bytes memory data = abi.encodeCall(IdentityRegistry.unfreeze, (alice));
        _refusedForAll(address(registry), data, Gate.Council, 0, _none());
        _viaCouncil(address(registry), data);
        assertFalse(registry.identityOf(alice).frozen);
    }

    // ----- compliance rules (the council only) -----

    function test_unauthorised_set_country_allowed_refused() public {
        bytes memory data = abi.encodeCall(ComplianceModule.setCountryAllowed, (BLOCKED, true));
        _refusedForAll(address(compliance), data, Gate.Council, 0, _none());
        _viaCouncil(address(compliance), data);
        assertTrue(compliance.countryAllowed(BLOCKED));
    }

    function test_unauthorised_set_max_holders_refused() public {
        bytes memory data = abi.encodeCall(ComplianceModule.setMaxHolders, (1));
        _refusedForAll(address(compliance), data, Gate.Council, 0, _none());
        _viaCouncil(address(compliance), data);
        assertEq(compliance.maxHolders(), 1);
    }

    function test_unauthorised_set_min_holding_refused() public {
        bytes memory data = abi.encodeCall(ComplianceModule.setMinHolding, (5000));
        _refusedForAll(address(compliance), data, Gate.Council, 0, _none());
        _viaCouncil(address(compliance), data);
        assertEq(compliance.minHolding(), 5000);
    }

    function test_unauthorised_set_lockup_end_refused() public {
        bytes memory data = abi.encodeCall(ComplianceModule.setLockupEnd, (uint64(START + 365 days)));
        _refusedForAll(address(compliance), data, Gate.Council, 0, _none());
        _viaCouncil(address(compliance), data);
        assertEq(compliance.lockupEnd(), START + 365 days);
    }

    // ----- token -----

    function test_unauthorised_mint_refused() public {
        bytes memory data = abi.encodeCall(PoolToken.mint, (alice, 1));
        _refusedForAll(address(token), data, Gate.Role, token.MINTER_ROLE(), _one(minter));
    }

    function test_unauthorised_batch_mint_refused() public {
        address[] memory tos = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        (tos[0], amounts[0]) = (alice, 1);
        bytes memory data = abi.encodeCall(PoolToken.batchMint, (tos, amounts));
        _refusedForAll(address(token), data, Gate.Role, token.MINTER_ROLE(), _one(minter));
    }

    function test_unauthorised_pause_refused() public {
        bytes memory data = abi.encodeCall(PoolToken.pause, ());
        _refusedForAll(address(token), data, Gate.RoleOrCouncil, token.AGENT_ROLE(), _one(agent));
    }

    function test_unauthorised_unpause_refused() public {
        vm.prank(agent);
        token.pause();
        bytes memory data = abi.encodeCall(PoolToken.unpause, ());
        _refusedForAll(address(token), data, Gate.Council, 0, _none());
        _viaCouncil(address(token), data);
        assertFalse(token.paused());
    }

    function test_unauthorised_freeze_tokens_refused() public {
        bytes memory data = abi.encodeCall(PoolToken.setFrozenTokens, (alice, 500));
        _refusedForAll(address(token), data, Gate.RoleOrCouncil, token.AGENT_ROLE(), _one(agent));
    }

    function test_unauthorised_unfreeze_tokens_refused() public {
        vm.prank(agent);
        token.setFrozenTokens(alice, 500);
        bytes memory data = abi.encodeCall(PoolToken.setFrozenTokens, (alice, 100));
        _refusedForAll(address(token), data, Gate.Council, 0, _none());
        _viaCouncil(address(token), data);
        assertEq(token.getFrozenTokens(alice), 100);
    }

    function test_unauthorised_forced_transfer_refused() public {
        bytes memory data = abi.encodeCall(PoolToken.forcedTransfer, (alice, bob, 100));
        _refusedForAll(address(token), data, Gate.Council, 0, _none());
        _viaCouncil(address(token), data);
        assertEq(token.balanceOf(bob), 100);
    }

    function test_unauthorised_recover_wallet_refused() public {
        address replacement = makeAddr("replacement");
        _registerAnotherWallet(replacement, ALICE_ID, CA);
        bytes memory data = abi.encodeCall(PoolToken.recoverWallet, (alice, replacement, ALICE_ID));
        _refusedForAll(address(token), data, Gate.Council, 0, _none());
        _viaCouncil(address(token), data);
        assertEq(token.balanceOf(replacement), 1000);
    }

    // ----- the council itself -----

    function test_unauthorised_propose_refused() public {
        bytes memory data = abi.encodeCall(Council.propose, (address(token), hex"", REASON));
        _refusedForAll(address(council), data, Gate.Member, 0, _members());
    }

    function test_unauthorised_approve_refused() public {
        vm.prank(m1);
        bytes32 id = council.propose(address(token), abi.encodeCall(PoolToken.unpause, ()), REASON);
        _refusedForAll(address(council), abi.encodeCall(Council.approve, (id)), Gate.Member, 0, _members());
    }

    function test_unauthorised_execute_refused() public {
        bytes memory call = abi.encodeCall(PoolToken.forcedTransfer, (alice, bob, 1));
        vm.prank(m1);
        bytes32 id = council.propose(address(token), call, REASON);
        vm.prank(m2);
        council.approve(id);
        vm.warp(block.timestamp + 1 days);
        _refusedForAll(address(council), abi.encodeCall(Council.execute, (id, call)), Gate.Member, 0, _members());
    }

    function test_unauthorised_set_members_refused() public {
        address[] memory next = new address[](3);
        (next[0], next[1], next[2]) = (outsider, alice, bob);
        _refusedForAll(address(council), abi.encodeCall(Council.setMembers, (next, 2)), Gate.Self, 0, _none());
    }

    function test_unauthorised_set_delay_refused() public {
        _refusedForAll(address(council), abi.encodeCall(Council.setDelay, (2 days)), Gate.Self, 0, _none());
    }

    // ----- no single key moves a holder's tokens -----

    function test_no_single_key_moves_a_holders_tokens() public {
        address[8] memory keys = [m1, m2, m3, registrar, agent, minter, outsider, bob];
        address spare = makeAddr("spare-wallet-of-a");
        _registerAnotherWallet(spare, ALICE_ID, CA);
        bytes memory forced = abi.encodeCall(PoolToken.forcedTransfer, (alice, bob, 1000));
        for (uint256 i = 0; i < keys.length; ++i) {
            vm.startPrank(keys[i]);
            (bool ok,) = address(token).call(forced);
            assertFalse(ok);
            (ok,) = address(token).call(abi.encodeCall(PoolToken.recoverWallet, (alice, spare, ALICE_ID)));
            assertFalse(ok);
            (ok,) = address(token).call(abi.encodeCall(token.transferFrom, (alice, bob, 1)));
            assertFalse(ok);
            vm.stopPrank();
        }
        // A member alone: proposed, never queued, so never executable, however long it waits.
        vm.prank(m1);
        bytes32 id = council.propose(address(token), forced, REASON);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(abi.encodeWithSelector(Council.NotQueued.selector, id));
        vm.prank(m1);
        council.execute(id, forced);
        assertEq(token.balanceOf(alice), 1000);
        assertEq(token.balanceOf(spare), 0);
    }

    // ----- a contract is never governed by a single key -----

    function test_a_weak_council_is_refused_at_deployment() public {
        address[] memory members = new address[](3);
        (members[0], members[1], members[2]) = (m1, m2, m3);
        // Reporting a strong threshold and delay is not enough: only this repository's
        // Council code, which enforces them, is accepted.
        address[5] memory weak = [
            address(new WeakCouncil(1, 1 days)),
            address(new WeakCouncil(2, 1 hours)),
            address(new WeakCouncil(2, 1 days)),
            address(new ForkedCouncil(members)),
            outsider
        ];
        for (uint256 i = 0; i < weak.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(CouncilGoverned.CouncilTooWeak.selector, weak[i]));
            deployer.registry(weak[i]);
        }
        assertEq(deployer.registry(address(council)).council(), address(council));
        address[] memory four = new address[](4);
        (four[0], four[1], four[2], four[3]) = (m1, m2, m3, outsider);
        address second = address(deployer.council(four, 3, 2 days));
        assertEq(deployer.registry(second).council(), second);
    }

    // ----- the council's own stop: cancel and revoke -----

    function test_unauthorised_cancel_refused() public {
        vm.prank(m1);
        bytes32 id = council.propose(address(token), abi.encodeCall(PoolToken.unpause, ()), REASON);
        _refusedForAll(address(council), abi.encodeCall(Council.cancel, (id)), Gate.Member, 0, _members());
        assertFalse(council.proposal(id).cancelled);
        assertEq(council.proposal(id).vetoes, 0);
    }

    function test_unauthorised_revoke_approval_refused() public {
        vm.prank(m1);
        bytes32 id = council.propose(address(token), abi.encodeCall(PoolToken.unpause, ()), REASON);
        _refusedForAll(address(council), abi.encodeCall(Council.revokeApproval, (id)), Gate.Member, 0, _members());
        assertEq(council.proposal(id).approvals, 1);
        assertTrue(council.hasApproved(id, m1));
    }

    // ----- an investor id, once bound to a wallet, moves only through the council -----

    function test_unauthorised_set_investor_id_refused() public {
        bytes memory data = abi.encodeCall(IdentityRegistry.setInvestorId, (alice, BOB_ID));
        _refusedForAll(address(registry), data, Gate.Council, 0, _none());
        assertEq(registry.investorIdOf(alice), ALICE_ID);
        _viaCouncil(address(registry), data);
        assertEq(registry.investorIdOf(alice), BOB_ID);
    }

    function test_a_wallets_investor_id_is_fixed_once_set() public {
        address attacker = makeAddr("wallet-of-x");
        bytes32 xId = keccak256("investor-x");
        _register(attacker, xId, CA);
        uint64 kyc = uint64(block.timestamp + 30 days);
        vm.startPrank(registrar);
        registry.remove(attacker);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.InvestorIdFixed.selector, attacker, xId));
        registry.register(attacker, ALICE_ID, CA, IdentityRegistry.InvestorType.Professional, kyc);
        assertEq(registry.investorIdOf(attacker), xId);
        assertFalse(registry.identityOf(attacker).registered);
        registry.register(attacker, xId, CA, IdentityRegistry.InvestorType.Professional, kyc);
        vm.stopPrank();
        assertEq(registry.investorIdOf(attacker), xId);
        vm.expectRevert(abi.encodeWithSelector(PoolToken.NotSameInvestor.selector, alice, attacker));
        vm.prank(address(council));
        token.recoverWallet(alice, attacker, ALICE_ID);
        assertEq(token.balanceOf(alice), 1000);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_set_investor_id_refuses_the_zero_id() public {
        vm.expectRevert(IdentityRegistry.BadInvestorId.selector);
        vm.prank(address(council));
        registry.setInvestorId(alice, bytes32(0));
        assertEq(registry.investorIdOf(alice), ALICE_ID);
    }

    function test_grant_role_refuses_the_zero_address() public {
        bytes32 role = token.MINTER_ROLE();
        vm.expectRevert(CouncilGoverned.ZeroAddress.selector);
        vm.prank(address(council));
        token.grantRole(role, address(0));
        assertFalse(token.hasRole(role, address(0)));
    }

    function test_minimum_holding_is_never_zero() public {
        vm.expectRevert(abi.encodeWithSelector(ComplianceModule.BadMinHolding.selector, 0));
        vm.prank(address(council));
        compliance.setMinHolding(0);
        assertEq(compliance.minHolding(), 1);
        uint16[] memory countries = new uint16[](1);
        countries[0] = CA;
        ComplianceModule.Rules memory rules = ComplianceModule.Rules({
            allowedCountries: countries, maxHolders: 50, minHolding: 0, lockupEnd: 0, decimals: 0
        });
        vm.expectRevert(abi.encodeWithSelector(ComplianceModule.BadMinHolding.selector, 0));
        deployer.compliance(address(council), registry, rules);
    }

    // ----- one wallet per investor id at registration; more only through the council -----

    function test_a_registrar_cannot_register_a_second_wallet_under_an_existing_id() public {
        uint64 kyc = uint64(block.timestamp + 30 days);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.InvestorIdTaken.selector, ALICE_ID));
        vm.prank(registrar);
        registry.register(outsider, ALICE_ID, CA, IdentityRegistry.InvestorType.Professional, kyc);
        assertFalse(registry.identityOf(outsider).registered);
        assertEq(registry.investorIdOf(outsider), bytes32(0));
        assertEq(registry.walletCount(ALICE_ID), 1);
        // Removing the first wallet does not free its id: the id stays for recovery.
        vm.prank(registrar);
        registry.remove(alice);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.InvestorIdTaken.selector, ALICE_ID));
        vm.prank(registrar);
        registry.register(outsider, ALICE_ID, CA, IdentityRegistry.InvestorType.Professional, kyc);
        assertFalse(registry.identityOf(outsider).registered);
        // The council binds the second wallet; then the registrar may register it.
        vm.prank(address(council));
        registry.setInvestorId(outsider, ALICE_ID);
        vm.prank(registrar);
        registry.register(outsider, ALICE_ID, CA, IdentityRegistry.InvestorType.Professional, kyc);
        assertTrue(registry.identityOf(outsider).registered);
        assertEq(registry.walletCount(ALICE_ID), 2);
    }

    function test_a_council_binding_takes_the_id() public {
        bytes32 freshId = keccak256("investor-fresh");
        address first = makeAddr("wallet-fresh-1");
        address second = makeAddr("wallet-fresh-2");
        vm.prank(address(council));
        registry.setInvestorId(first, freshId);
        assertEq(registry.walletCount(freshId), 1);
        uint64 kyc = uint64(block.timestamp + 30 days);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.InvestorIdTaken.selector, freshId));
        vm.prank(registrar);
        registry.register(second, freshId, CA, IdentityRegistry.InvestorType.Professional, kyc);
        assertFalse(registry.identityOf(second).registered);
        assertEq(registry.investorIdOf(second), bytes32(0));
        _register(first, freshId, CA);
        assertTrue(registry.identityOf(first).registered);
        assertEq(registry.walletCount(freshId), 1);
    }

    function test_rebinding_a_wallet_away_frees_its_old_id() public {
        bytes32 rightId = keccak256("investor-right");
        vm.prank(address(council));
        registry.setInvestorId(alice, rightId);
        assertEq(registry.walletCount(ALICE_ID), 0);
        assertEq(registry.walletCount(rightId), 1);
        _register(outsider, ALICE_ID, CA);
        assertEq(registry.investorIdOf(outsider), ALICE_ID);
        assertEq(registry.walletCount(ALICE_ID), 1);
        vm.prank(address(council));
        registry.setInvestorId(alice, rightId);
        assertEq(registry.walletCount(rightId), 1);
    }

    // ----- the minimum holding: at least one whole token, so a holder slot has a price -----

    function _rules(uint256 minHolding, uint8 decimals_) internal view returns (ComplianceModule.Rules memory) {
        uint16[] memory countries = new uint16[](1);
        countries[0] = CA;
        return ComplianceModule.Rules({
            allowedCountries: countries, maxHolders: 50, minHolding: minHolding, lockupEnd: 0, decimals: decimals_
        });
    }

    function test_minimum_holding_is_at_least_one_whole_token() public {
        vm.expectRevert(abi.encodeWithSelector(ComplianceModule.BadMinHolding.selector, 1e6 - 1));
        deployer.compliance(address(council), registry, _rules(1e6 - 1, 6));
        ComplianceModule six = deployer.compliance(address(council), registry, _rules(1e6, 6));
        assertEq(six.minHolding(), 1e6);
        assertEq(six.decimals(), 6);
        vm.expectRevert(abi.encodeWithSelector(ComplianceModule.BadMinHolding.selector, 1e6 - 1));
        vm.prank(address(council));
        six.setMinHolding(1e6 - 1);
        assertEq(six.minHolding(), 1e6);
        vm.expectRevert(abi.encodeWithSelector(ComplianceModule.BadDecimals.selector, 19));
        deployer.compliance(address(council), registry, _rules(1e19, 19));
    }

    /// The stated bound: filling `free` empty holder slots takes at least `free` x the
    /// minimum holding, each part in a separate registered investor's wallet.
    function testFuzz_filling_the_free_holder_slots_costs_free_times_the_minimum(uint256 free, uint256 minimum) public {
        free = bound(free, 1, 8);
        minimum = bound(minimum, 2, 100);
        uint256 holders = token.holderCount();
        vm.startPrank(address(council));
        compliance.setMinHolding(minimum);
        compliance.setMaxHolders(holders + free);
        vm.stopPrank();
        vm.prank(minter);
        token.mint(alice, free * minimum);
        uint256 aliceBefore = token.balanceOf(alice);
        for (uint256 i = 0; i < free; ++i) {
            address slot = makeAddr(string.concat("slot-", vm.toString(i)));
            _register(slot, keccak256(abi.encode("slot-investor", i)), CA);
            vm.expectRevert(_refused(alice, slot, minimum - 1, Refusal.ReceiverBelowMinimumHolding));
            vm.prank(alice);
            token.transfer(slot, minimum - 1);
            vm.prank(alice);
            token.transfer(slot, minimum);
        }
        assertEq(token.holderCount(), holders + free);
        assertEq(aliceBefore - token.balanceOf(alice), free * minimum);
        address extra = makeAddr("slot-extra");
        _register(extra, keccak256("slot-investor-extra"), CA);
        vm.expectRevert(_refused(alice, extra, minimum, Refusal.MaxHolders));
        vm.prank(alice);
        token.transfer(extra, minimum);
        assertEq(token.balanceOf(extra), 0);
    }

    // ----- registry inputs -----

    function test_registry_refuses_bad_claims() public {
        vm.startPrank(registrar);
        uint64 kyc = uint64(block.timestamp + 30 days);
        vm.expectRevert(CouncilGoverned.ZeroAddress.selector);
        registry.register(address(0), keccak256("z"), CA, IdentityRegistry.InvestorType.Retail, kyc);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.AlreadyRegistered.selector, alice));
        registry.register(alice, keccak256("z"), CA, IdentityRegistry.InvestorType.Retail, kyc);
        vm.expectRevert(IdentityRegistry.BadInvestorId.selector);
        registry.register(outsider, 0, CA, IdentityRegistry.InvestorType.Retail, kyc);
        vm.expectRevert(IdentityRegistry.BadInvestorType.selector);
        registry.register(outsider, keccak256("z"), CA, IdentityRegistry.InvestorType.None, kyc);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.BadCountry.selector, 0));
        registry.register(outsider, keccak256("z"), 0, IdentityRegistry.InvestorType.Retail, kyc);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.BadCountry.selector, 1000));
        registry.register(outsider, keccak256("z"), 1000, IdentityRegistry.InvestorType.Retail, kyc);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotRegistered.selector, outsider));
        registry.updateKyc(outsider, kyc);
        vm.stopPrank();
        assertFalse(registry.identityOf(outsider).registered);
    }

    function test_registry_bounds_the_kyc_expiry() public {
        uint64[2] memory bad = [uint64(block.timestamp), uint64(block.timestamp + 3 * 365 days + 1)];
        for (uint256 i = 0; i < 2; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.BadKycExpiry.selector, bad[i]));
            vm.prank(registrar);
            registry.updateKyc(alice, bad[i]);
        }
        assertEq(registry.identityOf(alice).kycExpiry, START + 365 days);
    }

    function test_freeze_survives_removal_and_re_registration() public {
        vm.prank(agent);
        registry.freeze(alice);
        vm.startPrank(registrar);
        registry.remove(alice);
        registry.register(alice, ALICE_ID, CA, IdentityRegistry.InvestorType.Retail, uint64(block.timestamp + 30 days));
        vm.stopPrank();
        assertTrue(registry.identityOf(alice).frozen);
        assertFalse(token.canSend(alice));
        assertTrue(registry.isVerified(alice));
    }

    function test_compliance_refuses_bad_rules() public {
        vm.startPrank(address(council));
        vm.expectRevert(abi.encodeWithSelector(ComplianceModule.BadMaxHolders.selector, 0));
        compliance.setMaxHolders(0);
        vm.expectRevert(abi.encodeWithSelector(ComplianceModule.BadCountry.selector, 0));
        compliance.setCountryAllowed(0, true);
        uint64 far = uint64(block.timestamp + 5 * 365 days + 1);
        vm.expectRevert(abi.encodeWithSelector(ComplianceModule.BadLockupEnd.selector, far));
        compliance.setLockupEnd(far);
        vm.stopPrank();
        assertEq(compliance.maxHolders(), 50);
        assertEq(compliance.lockupEnd(), 0);
    }
}
