// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.30;

import {ComplianceModule} from "../src/ComplianceModule.sol";
import {Council} from "../src/Council.sol";
import {CouncilGoverned} from "../src/CouncilGoverned.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {PoolToken} from "../src/PoolToken.sol";
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
        _register(replacement, ALICE_ID, CA);
        bytes memory data = abi.encodeCall(PoolToken.recoverWallet, (alice, replacement));
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
        address[] memory next = new address[](2);
        (next[0], next[1]) = (outsider, alice);
        _refusedForAll(address(council), abi.encodeCall(Council.setMembers, (next, 2)), Gate.Self, 0, _none());
    }

    function test_unauthorised_set_delay_refused() public {
        _refusedForAll(address(council), abi.encodeCall(Council.setDelay, (2 days)), Gate.Self, 0, _none());
    }

    // ----- no single key moves a holder's tokens -----

    function test_no_single_key_moves_a_holders_tokens() public {
        address[8] memory keys = [m1, m2, m3, registrar, agent, minter, outsider, bob];
        address spare = makeAddr("spare-wallet-of-a");
        _register(spare, ALICE_ID, CA);
        bytes memory forced = abi.encodeCall(PoolToken.forcedTransfer, (alice, bob, 1000));
        for (uint256 i = 0; i < keys.length; ++i) {
            vm.startPrank(keys[i]);
            (bool ok,) = address(token).call(forced);
            assertFalse(ok);
            (ok,) = address(token).call(abi.encodeCall(PoolToken.recoverWallet, (alice, spare)));
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
        address[3] memory weak = [address(new WeakCouncil(1, 1 days)), address(new WeakCouncil(2, 1 hours)), outsider];
        for (uint256 i = 0; i < weak.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(CouncilGoverned.CouncilTooWeak.selector, weak[i]));
            deployer.registry(weak[i]);
        }
        deployer.registry(address(new WeakCouncil(2, 1 days)));
        assertEq(deployer.registry(address(council)).council(), address(council));
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
