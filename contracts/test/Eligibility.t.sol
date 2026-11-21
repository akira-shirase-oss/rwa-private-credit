// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.30;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {PoolToken} from "../src/PoolToken.sol";
import {Refusal} from "../src/Refusal.sol";
import {IERC7943Fungible} from "../src/interfaces/IERC7943Fungible.sol";
import {Fixture} from "./Fixture.sol";

/// END_GOAL case 1 and invariant 1: every ineligible receiver is refused on every path a
/// token can move by, every ineligible sender on every path that has one, each with its
/// own refusal and with the stored state re-read unchanged afterwards.
contract EligibilityTest is Fixture {
    enum Path {
        Transfer,
        TransferFrom,
        BatchTransfer,
        Mint,
        BatchMint,
        Forced,
        Recover
    }

    enum BadReceiver {
        NeverRegistered,
        Removed,
        KycExpired,
        Frozen,
        Country,
        MaxHolders,
        BelowMinimum
    }

    enum BadSender {
        Removed,
        KycExpired,
        Frozen,
        Country,
        LockUp,
        BelowMinimum,
        FrozenTokens,
        InsufficientBalance,
        Paused
    }

    uint256 internal constant AMOUNT = 100;
    uint256 internal constant PATHS = 7;
    uint256 internal constant RECEIVERS = 7;
    uint256 internal constant SENDERS = 9;

    struct State {
        uint256 alice;
        uint256 bob;
        uint256 carol;
        uint256 to;
        uint256 supply;
        uint256 holders;
        uint256 aliceFrozen;
        uint256 allowance;
    }

    function setUp() public override {
        super.setUp();
        vm.prank(minter);
        token.mint(carol, 1000);
    }

    // ----- the matrix -----

    function _read(address to) internal view returns (State memory s) {
        s = State(
            token.balanceOf(alice),
            token.balanceOf(bob),
            token.balanceOf(carol),
            token.balanceOf(to),
            token.totalSupply(),
            token.holderCount(),
            token.getFrozenTokens(alice),
            token.allowance(alice, bob)
        );
    }

    function _assertSame(State memory a, State memory b) internal pure {
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)), "a refused move changed stored state");
    }

    /// Makes `to` an ineligible receiver of the given kind; returns the refusal, or false
    /// when the rule cannot apply on this path (a recovery never adds a holder).
    function _badReceiver(BadReceiver b, Path p) internal returns (address to, Refusal r, bool applies) {
        to = makeAddr(string.concat("bad-receiver-", vm.toString(uint256(b))));
        applies = true;
        if (b == BadReceiver.NeverRegistered) {
            r = Refusal.ReceiverNotRegistered;
            applies = p != Path.Recover; // the recovery refuses earlier: NotSameInvestor
        } else if (b == BadReceiver.Removed) {
            _register(to, ALICE_ID, CA);
            vm.prank(registrar);
            registry.remove(to);
            r = Refusal.ReceiverNotRegistered;
        } else if (b == BadReceiver.KycExpired) {
            vm.prank(registrar);
            registry.register(to, ALICE_ID, CA, IdentityRegistry.InvestorType.Retail, uint64(block.timestamp + 1 days));
            vm.warp(block.timestamp + 1 days);
            r = Refusal.ReceiverKycExpired;
        } else if (b == BadReceiver.Frozen) {
            _register(to, ALICE_ID, CA);
            vm.prank(agent);
            registry.freeze(to);
            r = Refusal.ReceiverFrozen;
        } else if (b == BadReceiver.Country) {
            _register(to, ALICE_ID, BLOCKED);
            r = Refusal.ReceiverCountryNotAllowed;
        } else if (b == BadReceiver.MaxHolders) {
            _register(to, ALICE_ID, US);
            uint256 holders = token.holderCount();
            vm.prank(address(council));
            compliance.setMaxHolders(holders);
            r = Refusal.MaxHolders;
            applies = p != Path.Recover;
        } else {
            _register(to, ALICE_ID, US);
            vm.prank(address(council));
            compliance.setMinHolding(p == Path.Recover ? 2000 : 600);
            r = Refusal.ReceiverBelowMinimumHolding;
        }
    }

    /// Moves `amount` from alice (or mints it) to `to` by path `p`, expecting `err`. The
    /// batches lead with a valid leg to carol, so all-or-nothing is checked too.
    function _approve(Path p, uint256 amount) internal {
        if (p == Path.TransferFrom) {
            vm.prank(alice);
            token.approve(bob, amount);
        }
    }

    function _move(Path p, address to, uint256 amount, bytes memory err, bool lead) internal {
        address[] memory tos = new address[](lead ? 2 : 1);
        uint256[] memory amounts = new uint256[](lead ? 2 : 1);
        tos[tos.length - 1] = to;
        amounts[amounts.length - 1] = amount;
        if (lead) {
            tos[0] = carol;
            amounts[0] = 1;
        }
        vm.expectRevert(err);
        if (p == Path.Transfer) {
            vm.prank(alice);
            token.transfer(to, amount);
        } else if (p == Path.TransferFrom) {
            vm.prank(bob);
            token.transferFrom(alice, to, amount);
        } else if (p == Path.BatchTransfer) {
            vm.prank(alice);
            token.batchTransfer(tos, amounts);
        } else if (p == Path.Mint) {
            vm.prank(minter);
            token.mint(to, amount);
        } else if (p == Path.BatchMint) {
            vm.prank(minter);
            token.batchMint(tos, amounts);
        } else if (p == Path.Forced) {
            vm.prank(address(council));
            token.forcedTransfer(alice, to, amount);
        } else {
            vm.prank(address(council));
            token.recoverWallet(alice, to, ALICE_ID);
        }
    }

    function _receiverCase(Path p, BadReceiver b) internal {
        uint256 snap = vm.snapshotState();
        (address to, Refusal r, bool applies) = _badReceiver(b, p);
        if (applies) {
            uint256 amount = p == Path.Recover ? token.balanceOf(alice) : AMOUNT;
            address from = p == Path.Mint || p == Path.BatchMint ? address(0) : alice;
            _approve(p, amount);
            State memory before = _read(to);
            _move(p, to, amount, _refused(from, to, amount, r), true);
            _assertSame(before, _read(to));
            assertEq(token.balanceOf(to), 0, "an ineligible receiver holds tokens");
        }
        vm.revertToState(snap);
    }

    function _everyReceiver(Path p) internal {
        for (uint256 b = 0; b < RECEIVERS; ++b) {
            _receiverCase(p, BadReceiver(b));
        }
    }

    function _everyPath(BadReceiver b) internal {
        for (uint256 p = 0; p < PATHS; ++p) {
            _receiverCase(Path(p), b);
        }
    }

    /// Makes alice an ineligible sender of the given kind; returns the expected error.
    function _badSender(BadSender b, Path p) internal returns (bytes memory err, uint256 amount) {
        amount = AMOUNT;
        address from = p == Path.Mint || p == Path.BatchMint ? address(0) : alice;
        Refusal r;
        if (b == BadSender.Removed) {
            vm.prank(registrar);
            registry.remove(alice);
            r = Refusal.SenderNotRegistered;
        } else if (b == BadSender.KycExpired) {
            vm.prank(registrar);
            registry.updateKyc(alice, uint64(block.timestamp + 1 days));
            vm.warp(block.timestamp + 1 days);
            r = Refusal.SenderKycExpired;
        } else if (b == BadSender.Frozen) {
            vm.prank(agent);
            registry.freeze(alice);
            r = Refusal.SenderFrozen;
        } else if (b == BadSender.Country) {
            vm.prank(registrar);
            registry.updateCountry(alice, BLOCKED);
            r = Refusal.SenderCountryNotAllowed;
        } else if (b == BadSender.LockUp) {
            vm.prank(address(council));
            compliance.setLockupEnd(uint64(block.timestamp + 30 days));
            r = Refusal.LockUp;
        } else if (b == BadSender.BelowMinimum) {
            vm.prank(address(council));
            compliance.setMinHolding(950);
            r = Refusal.SenderBelowMinimumHolding;
        } else if (b == BadSender.FrozenTokens) {
            vm.prank(agent);
            token.setFrozenTokens(alice, 950);
            return (
                abi.encodeWithSelector(IERC7943Fungible.ERC7943InsufficientUnfrozenBalance.selector, alice, amount, 50),
                amount
            );
        } else if (b == BadSender.InsufficientBalance) {
            amount = 1001;
            return (abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1000, amount), amount);
        } else {
            vm.prank(agent);
            token.pause();
            r = Refusal.Paused;
        }
        err = _refused(from, bob, amount, r);
    }

    function _senderCase(Path p, BadSender b) internal {
        uint256 snap = vm.snapshotState();
        (bytes memory err, uint256 amount) = _badSender(b, p);
        _approve(p, amount);
        State memory before = _read(bob);
        _move(p, bob, amount, err, false);
        _assertSame(before, _read(bob));
        vm.revertToState(snap);
    }

    function _everySenderPath(BadSender b) internal {
        _senderCase(Path.Transfer, b);
        _senderCase(Path.TransferFrom, b);
        _senderCase(Path.BatchTransfer, b);
    }

    // ----- every ineligible receiver, on every path -----

    function test_receiver_never_registered_refused_on_every_path() public {
        _everyPath(BadReceiver.NeverRegistered);
    }

    function test_receiver_removed_refused_on_every_path() public {
        _everyPath(BadReceiver.Removed);
    }

    function test_receiver_kyc_expired_refused_on_every_path() public {
        _everyPath(BadReceiver.KycExpired);
    }

    function test_receiver_frozen_refused_on_every_path() public {
        _everyPath(BadReceiver.Frozen);
    }

    function test_receiver_country_refused_on_every_path() public {
        _everyPath(BadReceiver.Country);
    }

    function test_receiver_over_max_holders_refused_on_every_path() public {
        _everyPath(BadReceiver.MaxHolders);
    }

    function test_receiver_under_minimum_holding_refused_on_every_path() public {
        _everyPath(BadReceiver.BelowMinimum);
    }

    // ----- every path refuses every ineligible receiver -----

    function test_path_transfer_refuses_every_ineligible_receiver() public {
        _everyReceiver(Path.Transfer);
    }

    function test_path_transfer_from_refuses_every_ineligible_receiver() public {
        _everyReceiver(Path.TransferFrom);
    }

    function test_path_batch_transfer_refuses_every_ineligible_receiver() public {
        _everyReceiver(Path.BatchTransfer);
    }

    function test_path_mint_refuses_every_ineligible_receiver() public {
        _everyReceiver(Path.Mint);
    }

    function test_path_batch_mint_refuses_every_ineligible_receiver() public {
        _everyReceiver(Path.BatchMint);
    }

    function test_path_forced_refuses_every_ineligible_receiver() public {
        _everyReceiver(Path.Forced);
    }

    function test_path_recover_refuses_every_ineligible_receiver() public {
        _everyReceiver(Path.Recover);
    }

    function testFuzz_ineligible_receiver_refused(uint8 path, uint8 kind, uint32 wait) public {
        vm.warp(block.timestamp + bound(wait, 0, 300 days));
        _receiverCase(Path(bound(path, 0, PATHS - 1)), BadReceiver(bound(kind, 0, RECEIVERS - 1)));
    }

    // ----- every ineligible sender, on every holder path -----

    function test_sender_removed_refused() public {
        _everySenderPath(BadSender.Removed);
    }

    function test_sender_kyc_expired_refused() public {
        _everySenderPath(BadSender.KycExpired);
    }

    function test_sender_frozen_refused() public {
        _everySenderPath(BadSender.Frozen);
    }

    function test_sender_country_refused() public {
        _everySenderPath(BadSender.Country);
    }

    function test_sender_inside_lockup_refused() public {
        _everySenderPath(BadSender.LockUp);
    }

    function test_sender_left_under_minimum_refused() public {
        _everySenderPath(BadSender.BelowMinimum);
    }

    function test_sender_frozen_tokens_refused() public {
        _everySenderPath(BadSender.FrozenTokens);
    }

    function test_sender_insufficient_balance_refused() public {
        _everySenderPath(BadSender.InsufficientBalance);
    }

    function test_paused_refuses_holder_paths_and_mints() public {
        _everySenderPath(BadSender.Paused);
        _senderCase(Path.Mint, BadSender.Paused);
        _senderCase(Path.BatchMint, BadSender.Paused);
    }

    function testFuzz_ineligible_sender_refused(uint8 path, uint8 kind) public {
        _senderCase(Path(bound(path, 0, 2)), BadSender(bound(kind, 0, SENDERS - 1)));
    }

    // ----- the moves that do go through -----

    function test_eligible_moves_succeed_on_every_path() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 10));
        vm.prank(alice);
        token.approve(bob, 10);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, 10));
        address[] memory tos = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (tos[0], tos[1], amounts[0], amounts[1]) = (bob, carol, 5, 5);
        vm.prank(alice);
        assertTrue(token.batchTransfer(tos, amounts));
        vm.prank(minter);
        token.batchMint(tos, amounts);
        vm.prank(address(council));
        assertTrue(token.forcedTransfer(alice, bob, 70));
        assertEq(token.balanceOf(alice), 900);
        assertEq(token.balanceOf(bob), 90);
        assertEq(token.balanceOf(carol), 1020);
        assertEq(token.totalSupply(), 2010);
        assertEq(token.holderCount(), 3);
    }

    function test_holder_count_follows_balances() public {
        assertEq(token.holderCount(), 2);
        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.holderCount(), 3);
        vm.prank(bob);
        token.transfer(alice, 1);
        assertEq(token.holderCount(), 2);
        vm.prank(alice);
        token.transfer(alice, 5);
        vm.prank(alice);
        token.transfer(bob, 0);
        assertEq(token.holderCount(), 2);
        assertEq(token.balanceOf(alice), 1000);
    }

    function test_leaving_with_the_whole_balance_is_not_under_minimum() public {
        vm.prank(address(council));
        compliance.setMinHolding(600);
        vm.prank(alice);
        token.transfer(bob, 1000);
        assertEq(token.balanceOf(bob), 1000);
        assertEq(token.holderCount(), 2);
    }

    function test_lockup_ends_on_time() public {
        vm.prank(address(council));
        compliance.setLockupEnd(uint64(block.timestamp + 10 days));
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.balanceOf(bob), 1);
    }

    /// A forced move skips the sender's rules (that is what it is for) but not the receiver's.
    function test_forced_moves_tokens_of_an_ineligible_sender_and_releases_frozen() public {
        vm.prank(agent);
        token.setFrozenTokens(alice, 1000);
        vm.prank(agent);
        registry.freeze(alice);
        vm.prank(agent);
        token.pause();
        vm.warp(block.timestamp + 400 days);
        vm.prank(registrar);
        registry.updateKyc(bob, uint64(block.timestamp + 30 days));
        vm.prank(address(council));
        token.forcedTransfer(alice, bob, 400);
        assertEq(token.balanceOf(alice), 600);
        assertEq(token.balanceOf(bob), 400);
        assertEq(token.getFrozenTokens(alice), 600);
    }

    function test_forced_refuses_more_than_the_balance_and_same_wallet() public {
        vm.startPrank(address(council));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1000, 1001));
        token.forcedTransfer(alice, bob, 1001);
        vm.expectRevert(PoolToken.SameWallet.selector);
        token.forcedTransfer(alice, alice, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1000);
    }

    function test_recover_moves_the_whole_balance_and_the_frozen_part_to_the_same_investor() public {
        address replacement = makeAddr("replacement");
        _register(replacement, ALICE_ID, US);
        vm.prank(agent);
        token.setFrozenTokens(alice, 300);
        vm.prank(registrar);
        registry.remove(alice);
        vm.prank(address(council));
        token.recoverWallet(alice, replacement, ALICE_ID);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(replacement), 1000);
        assertEq(token.getFrozenTokens(alice), 0);
        assertEq(token.getFrozenTokens(replacement), 300);
        assertEq(token.holderCount(), 2);
    }

    function test_recover_refuses_another_investors_wallet() public {
        address[2] memory others = [bob, outsider];
        for (uint256 i = 0; i < 2; ++i) {
            vm.expectRevert(abi.encodeWithSelector(PoolToken.NotSameInvestor.selector, alice, others[i]));
            vm.prank(address(council));
            token.recoverWallet(alice, others[i], ALICE_ID);
        }
        vm.expectRevert(abi.encodeWithSelector(PoolToken.NotSameInvestor.selector, outsider, alice));
        vm.prank(address(council));
        token.recoverWallet(outsider, alice, ALICE_ID);
        assertEq(token.balanceOf(alice), 1000);
        assertEq(token.balanceOf(bob), 0);
    }

    /// The proposal names the investor id; both wallets must carry it.
    function test_recover_is_bound_to_the_proposed_investor_id() public {
        address spare = makeAddr("spare-wallet-of-a");
        _register(spare, ALICE_ID, CA);
        vm.prank(alice);
        token.transfer(bob, 400);
        vm.startPrank(address(council));
        vm.expectRevert(abi.encodeWithSelector(PoolToken.NotSameInvestor.selector, bob, spare));
        token.recoverWallet(bob, spare, ALICE_ID);
        vm.expectRevert(abi.encodeWithSelector(PoolToken.NotSameInvestor.selector, alice, spare));
        token.recoverWallet(alice, spare, BOB_ID);
        vm.expectRevert(abi.encodeWithSelector(PoolToken.NotSameInvestor.selector, alice, spare));
        token.recoverWallet(alice, spare, bytes32(0));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 600);
        assertEq(token.balanceOf(bob), 400);
        assertEq(token.balanceOf(spare), 0);
    }

    /// A forced move spends the unfrozen part first and releases only the frozen part it
    /// moves, even when more is frozen than held.
    function test_forced_releases_only_the_frozen_part_it_moves() public {
        vm.prank(agent);
        token.setFrozenTokens(alice, 1500);
        vm.prank(address(council));
        token.forcedTransfer(alice, bob, 400);
        assertEq(token.getFrozenTokens(alice), 1100);
        vm.prank(agent);
        token.setFrozenTokens(bob, 100);
        uint256 carolBefore = token.balanceOf(carol);
        vm.prank(address(council));
        token.forcedTransfer(bob, carol, 350);
        assertEq(token.getFrozenTokens(bob), 50);
        assertEq(token.balanceOf(carol), carolBefore + 350);
    }

    function test_recover_leaves_the_frozen_excess_on_the_lost_wallet() public {
        address replacement = makeAddr("replacement");
        _register(replacement, ALICE_ID, CA);
        vm.prank(agent);
        token.setFrozenTokens(alice, 1500);
        vm.prank(address(council));
        token.recoverWallet(alice, replacement, ALICE_ID);
        assertEq(token.getFrozenTokens(alice), 500);
        assertEq(token.getFrozenTokens(replacement), 1000);
        assertEq(token.balanceOf(replacement), 1000);
    }

    function test_frozen_changes_record_who_acted() public {
        vm.expectEmit(address(token));
        emit IERC7943Fungible.Frozen(alice, 500);
        vm.expectEmit(address(token));
        emit PoolToken.FrozenTokensChanged(alice, 500, agent);
        vm.prank(agent);
        token.setFrozenTokens(alice, 500);
        vm.expectEmit(address(token));
        emit IERC7943Fungible.Frozen(alice, 100);
        vm.expectEmit(address(token));
        emit PoolToken.FrozenTokensChanged(alice, 100, address(council));
        vm.prank(address(council));
        token.forcedTransfer(alice, bob, 900);
        assertEq(token.getFrozenTokens(alice), 100);
    }

    function test_dust_cannot_take_a_holder_slot() public {
        uint256 holders = token.holderCount();
        vm.startPrank(address(council));
        compliance.setMinHolding(100);
        compliance.setMaxHolders(holders + 1);
        vm.stopPrank();
        vm.expectRevert(_refused(alice, bob, 1, Refusal.ReceiverBelowMinimumHolding));
        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.holderCount(), holders);
        assertEq(token.balanceOf(bob), 0);
        vm.prank(alice);
        token.transfer(bob, 100);
        assertEq(token.holderCount(), holders + 1);
    }

    function test_recover_refuses_an_empty_wallet_and_the_same_wallet() public {
        address replacement = makeAddr("replacement");
        _register(replacement, BOB_ID, US);
        vm.startPrank(address(council));
        vm.expectRevert(abi.encodeWithSelector(PoolToken.NothingToRecover.selector, bob));
        token.recoverWallet(bob, replacement, BOB_ID);
        vm.expectRevert(PoolToken.SameWallet.selector);
        token.recoverWallet(alice, alice, ALICE_ID);
        vm.stopPrank();
    }

    function test_batches_are_bounded_and_matched() public {
        address[] memory tos = new address[](101);
        uint256[] memory amounts = new uint256[](101);
        for (uint256 i = 0; i < 101; ++i) {
            (tos[i], amounts[i]) = (bob, 1);
        }
        vm.expectRevert(abi.encodeWithSelector(PoolToken.BatchTooLarge.selector, 101));
        vm.prank(alice);
        token.batchTransfer(tos, amounts);
        vm.expectRevert(abi.encodeWithSelector(PoolToken.BatchTooLarge.selector, 101));
        vm.prank(minter);
        token.batchMint(tos, amounts);
        vm.expectRevert(PoolToken.LengthMismatch.selector);
        vm.prank(alice);
        token.batchTransfer(tos, new uint256[](1));
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(alice), 1000);
    }

    function test_frozen_tokens_bound_only_the_frozen_part() public {
        vm.prank(agent);
        token.setFrozenTokens(alice, 900);
        vm.prank(alice);
        token.transfer(bob, 100);
        assertEq(token.balanceOf(bob), 100);
        assertFalse(token.canTransfer(alice, bob, 1));
    }

    // ----- ERC-7943 views agree with what the token does -----

    function test_erc7943_views() public {
        assertTrue(token.supportsInterface(type(IERC7943Fungible).interfaceId));
        assertTrue(token.supportsInterface(0x01ffc9a7));
        assertFalse(token.supportsInterface(0xffffffff));
        assertTrue(token.canSend(alice));
        assertTrue(token.canReceive(bob));
        assertFalse(token.canReceive(outsider));
        assertTrue(token.canTransfer(alice, bob, 1000));
        // More than the balance exceeds the unfrozen amount, so false (docs/DECISIONS.md D-005).
        assertFalse(token.canTransfer(alice, bob, 1001));
        assertFalse(token.canTransfer(alice, outsider, 1));
        vm.prank(agent);
        registry.freeze(alice);
        assertFalse(token.canSend(alice));
        assertFalse(token.canReceive(alice));
        assertEq(uint8(token.transferRefusal(alice, bob, 1)), uint8(Refusal.SenderFrozen));
        vm.prank(agent);
        token.setFrozenTokens(bob, 7);
        assertEq(token.getFrozenTokens(bob), 7);
    }

    function test_token_wiring_is_checked() public {
        vm.expectRevert(PoolToken.BadDecimals.selector);
        deployer.token(19, address(council), compliance);
        address[] memory members = new address[](2);
        (members[0], members[1]) = (m1, m2);
        address other = address(deployer.council(members, 2, 1 days));
        vm.expectRevert(PoolToken.RegistryMismatch.selector);
        deployer.token(6, other, compliance);
        assertEq(token.decimals(), 6);
    }
}
