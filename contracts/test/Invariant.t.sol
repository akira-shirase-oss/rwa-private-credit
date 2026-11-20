// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ComplianceModule} from "../src/ComplianceModule.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {PoolToken} from "../src/PoolToken.sol";
import {Refusal} from "../src/Refusal.sol";
import {Fixture} from "./Fixture.sol";

/// Drives every path a token can move by (transfer, transferFrom, batchTransfer, mint,
/// batchMint, forcedTransfer, recoverWallet) interleaved with every change to someone's
/// eligibility (register, remove, KYC, country, freeze, frozen tokens, pause, the rules,
/// time). Before each move it reads the rules as they stand; a move that succeeds while
/// they say no is counted as a violation.
contract Handler is Test {
    PoolToken internal immutable token;
    IdentityRegistry internal immutable registry;
    ComplianceModule internal immutable compliance;
    address internal immutable council;
    address internal immutable registrar;
    address internal immutable agent;
    address internal immutable minter;

    address[] public actors;
    uint256 public violations;
    mapping(bytes32 path => uint256) public moved;
    uint16[4] internal countries = [124, 840, 408, 276];

    constructor(PoolToken token_, address registrar_, address agent_, address minter_) {
        token = token_;
        registry = token_.registry();
        compliance = token_.compliance();
        council = token_.council();
        (registrar, agent, minter) = (registrar_, agent_, minter_);
        for (uint256 i = 0; i < 8; ++i) {
            actors.push(makeAddr(string.concat("actor-", vm.toString(i))));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _receiverOk(address to) internal view returns (bool) {
        (bool registered, uint64 kycExpiry, uint16 country, bool frozen) = registry.eligibility(to);
        return registered && kycExpiry > block.timestamp && !frozen && compliance.countryAllowed(country);
    }

    function _senderOk(address from, address to, uint256 amount) internal view returns (bool) {
        uint256 balance = token.balanceOf(from);
        uint256 frozen = token.getFrozenTokens(from);
        // A move to oneself leaves the balance as it is.
        uint256 after_ = from == to ? balance : balance >= amount ? balance - amount : 0;
        return _receiverOk(from) && !token.paused() && block.timestamp >= compliance.lockupEnd()
            && amount <= (frozen >= balance ? 0 : balance - frozen)
            && (after_ == 0 || after_ >= compliance.minHolding());
    }

    /// The receiver's side of a move as the rules stand now.
    function _destinationOk(address from, address to, uint256 amount) internal view returns (bool) {
        if (!_receiverOk(to)) return false;
        if (from == to || amount == 0) return true;
        uint256 toAfter = token.balanceOf(to) + amount;
        if (toAfter < compliance.minHolding()) return false;
        uint256 holders = token.holderCount();
        if (token.balanceOf(to) == 0) {
            holders += 1;
            if (from != address(0) && token.balanceOf(from) == amount) holders -= 1;
            if (holders > compliance.maxHolders()) return false;
        }
        return true;
    }

    function _record(bytes32 path, bool ok, bool allowed) internal {
        if (ok) {
            ++moved[path];
            if (!allowed) ++violations;
        }
    }

    // ----- the paths a token can move by -----

    function transfer(uint256 a, uint256 b, uint256 amount) external {
        (address from, address to) = (_actor(a), _actor(b));
        amount = bound(amount, 0, token.balanceOf(from) + 1);
        bool allowed = _senderOk(from, to, amount) && _destinationOk(from, to, amount);
        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (to, amount)));
        _record("transfer", ok, allowed);
    }

    function transferFrom(uint256 a, uint256 b, uint256 s, uint256 amount) external {
        (address from, address to, address spender) = (_actor(a), _actor(b), _actor(s));
        amount = bound(amount, 0, token.balanceOf(from) + 1);
        vm.prank(from);
        token.approve(spender, amount);
        bool allowed = _senderOk(from, to, amount) && _destinationOk(from, to, amount);
        vm.prank(spender);
        (bool ok,) = address(token).call(abi.encodeCall(token.transferFrom, (from, to, amount)));
        _record("transferFrom", ok, allowed);
    }

    function batchTransfer(uint256 a, uint256 b, uint256 amount) external {
        (address from, address to) = (_actor(a), _actor(b));
        amount = bound(amount, 0, token.balanceOf(from) + 1);
        bool allowed = _senderOk(from, to, amount) && _destinationOk(from, to, amount);
        address[] memory tos = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        (tos[0], amounts[0]) = (to, amount);
        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeCall(PoolToken.batchTransfer, (tos, amounts)));
        _record("batchTransfer", ok, allowed);
    }

    function mint(uint256 b, uint256 amount) external {
        address to = _actor(b);
        amount = bound(amount, 0, 1e12);
        bool allowed = !token.paused() && _destinationOk(address(0), to, amount);
        vm.prank(minter);
        (bool ok,) = address(token).call(abi.encodeCall(PoolToken.mint, (to, amount)));
        _record("mint", ok, allowed);
    }

    function batchMint(uint256 b, uint256 c, uint256 amount) external {
        (address to1, address to2) = (_actor(b), _actor(c));
        amount = bound(amount, 0, 1e12);
        // The second leg is judged after the first: run the first alone to see the rules then.
        bool allowed = !token.paused() && _destinationOk(address(0), to1, amount);
        address[] memory tos = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (tos[0], tos[1], amounts[0], amounts[1]) = (to1, to2, amount, amount);
        uint256 snap = vm.snapshotState();
        vm.prank(minter);
        (bool first,) = address(token).call(abi.encodeCall(PoolToken.mint, (to1, amount)));
        allowed = allowed && first && _destinationOk(address(0), to2, amount);
        vm.revertToState(snap);
        vm.prank(minter);
        (bool ok,) = address(token).call(abi.encodeCall(PoolToken.batchMint, (tos, amounts)));
        _record("batchMint", ok, allowed);
    }

    function forcedTransfer(uint256 a, uint256 b, uint256 amount) external {
        (address from, address to) = (_actor(a), _actor(b));
        amount = bound(amount, 0, token.balanceOf(from));
        bool allowed = _destinationOk(from, to, amount);
        vm.prank(council);
        (bool ok,) = address(token).call(abi.encodeCall(PoolToken.forcedTransfer, (from, to, amount)));
        _record("forcedTransfer", ok, allowed);
    }

    function recoverWallet(uint256 a, uint256 b) external {
        (address lost, address replacement) = (_actor(a), _actor(b));
        bool allowed = _destinationOk(lost, replacement, token.balanceOf(lost));
        vm.prank(council);
        (bool ok,) = address(token).call(abi.encodeCall(PoolToken.recoverWallet, (lost, replacement)));
        _record("recoverWallet", ok, allowed);
    }

    // ----- changes to eligibility -----

    function register(uint256 a, uint256 id, uint256 country, uint256 validity) external {
        address who = _actor(a);
        bytes32 investorId = keccak256(abi.encode("synthetic", id % 4));
        vm.prank(registrar);
        (bool ok,) = address(registry)
            .call(
                abi.encodeCall(
                    IdentityRegistry.register,
                    (
                        who,
                        investorId,
                        countries[country % 4],
                        IdentityRegistry.InvestorType.Professional,
                        uint64(block.timestamp + bound(validity, 1, 60 days))
                    )
                )
            );
        ok;
    }

    function remove(uint256 a) external {
        vm.prank(registrar);
        (bool ok,) = address(registry).call(abi.encodeCall(IdentityRegistry.remove, (_actor(a))));
        ok;
    }

    function updateKyc(uint256 a, uint256 validity) external {
        vm.prank(registrar);
        (bool ok,) = address(registry)
            .call(
                abi.encodeCall(
                    IdentityRegistry.updateKyc, (_actor(a), uint64(block.timestamp + bound(validity, 1, 60 days)))
                )
            );
        ok;
    }

    function updateCountry(uint256 a, uint256 country) external {
        vm.prank(registrar);
        (bool ok,) =
            address(registry).call(abi.encodeCall(IdentityRegistry.updateCountry, (_actor(a), countries[country % 4])));
        ok;
    }

    function freeze(uint256 a, bool on) external {
        if (on) {
            vm.prank(agent);
            registry.freeze(_actor(a));
        } else {
            vm.prank(council);
            registry.unfreeze(_actor(a));
        }
    }

    function setFrozenTokens(uint256 a, uint256 amount) external {
        vm.prank(council);
        token.setFrozenTokens(_actor(a), bound(amount, 0, 1e12));
    }

    function pause(bool on) external {
        vm.prank(council);
        if (on) token.pause();
        else token.unpause();
    }

    function setRules(uint256 maxHolders, uint256 minHolding, uint256 lockup, uint256 country, bool allowed) external {
        vm.startPrank(council);
        compliance.setMaxHolders(bound(maxHolders, 1, 8));
        compliance.setMinHolding(bound(minHolding, 0, 1000));
        compliance.setLockupEnd(uint64(block.timestamp + bound(lockup, 0, 3 days)) - 1 days);
        compliance.setCountryAllowed(countries[country % 4], allowed);
        vm.stopPrank();
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 20 days));
    }
}

/// The M1 invariant `destinations_always_eligible` (END_GOAL invariant 1, case 1).
contract DestinationsAlwaysEligibleTest is Fixture {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(token, registrar, agent, minter);
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            if (i < 6) _register(a, keccak256(abi.encode("synthetic", i % 4)), i % 2 == 0 ? CA : US);
            if (i < 4) {
                vm.prank(minter);
                token.mint(a, 10_000);
            }
        }
        targetContract(address(handler));
    }

    function invariant_destinations_always_eligible() public view {
        assertEq(handler.violations(), 0, "a token moved against the rules");
    }

    /// Every token sits with an actor, alice or nobody; the holder count is exact.
    function invariant_supply_and_holders_are_exact() public view {
        uint256 sum = token.balanceOf(alice);
        uint256 holders = token.balanceOf(alice) == 0 ? 0 : 1;
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            uint256 b = token.balanceOf(handler.actors(i));
            sum += b;
            if (b != 0) ++holders;
        }
        assertEq(sum, token.totalSupply());
        assertEq(holders, token.holderCount());
    }

    /// The handler can move by every path (so the campaign is not vacuous) and flags a
    /// move against the rules: a fixed sequence through each.
    function test_handler_moves_by_every_path() public {
        handler.transfer(0, 1, 10);
        handler.transferFrom(0, 2, 7, 10);
        handler.batchTransfer(1, 3, 10);
        handler.mint(4, 500);
        handler.batchMint(4, 5, 500);
        handler.forcedTransfer(2, 0, 5);
        handler.recoverWallet(0, 4);
        bytes32[7] memory paths = [
            bytes32("transfer"), "transferFrom", "batchTransfer", "mint", "batchMint", "forcedTransfer", "recoverWallet"
        ];
        for (uint256 i = 0; i < paths.length; ++i) {
            assertGt(handler.moved(paths[i]), 0, "a path was never exercised");
        }
        assertEq(handler.violations(), 0);
        handler.mint(6, 500);
        assertEq(handler.moved("mint"), 1, "a mint to an unregistered actor went through");
    }
}
