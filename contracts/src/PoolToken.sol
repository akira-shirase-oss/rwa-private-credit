// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ComplianceModule} from "./ComplianceModule.sol";
import {CouncilGoverned} from "./CouncilGoverned.sol";
import {IdentityRegistry} from "./IdentityRegistry.sol";
import {Refusal} from "./Refusal.sol";
import {IERC7943Fungible} from "./interfaces/IERC7943Fungible.sol";

/// A permissioned pool token on the ERC-3643 pattern with the ERC-7943 interface, written
/// clean-room from the ERC texts. Every balance change — transfer, transferFrom,
/// batchTransfer, mint, batchMint, forcedTransfer, recoverWallet — passes through one
/// hook, `_update`, which asks the compliance module and reverts unless the receiver is
/// registered, KYC-valid, unfrozen, from an allowed country and within the holder and
/// minimum-holding rules (invariant 1). Only forced moves, which only the council can make,
/// skip the sender's rules. There is no burn in M1 and no upgrade path.
contract PoolToken is ERC20, CouncilGoverned, IERC7943Fungible {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");

    uint256 public constant MAX_BATCH = 100;

    ComplianceModule public immutable compliance;
    IdentityRegistry public immutable registry;
    uint8 private immutable _decimals;

    bool public paused;
    uint256 public holderCount;
    mapping(address account => uint256) private _frozenTokens;
    /// Set only for the duration of a council forced move.
    bool private transient _forcing;

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event WalletRecovered(address indexed lost, address indexed replacement, uint256 amount);
    /// Emitted with every ERC-7943 `Frozen`, naming who changed the frozen amount.
    event FrozenTokensChanged(address indexed account, uint256 amount, address indexed by);

    error TransferRefused(address from, address to, uint256 amount, Refusal reason);
    error BatchTooLarge(uint256 length);
    error LengthMismatch();
    error BadDecimals();
    error RegistryMismatch();
    error SameWallet();
    error NotSameInvestor(address lost, address replacement);
    error NothingToRecover(address lost);

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address council_,
        ComplianceModule compliance_
    ) ERC20(name_, symbol_) CouncilGoverned(council_) {
        if (decimals_ > 18) revert BadDecimals();
        if (address(compliance_) == address(0)) revert ZeroAddress();
        IdentityRegistry registry_ = compliance_.registry();
        if (registry_.council() != council_ || compliance_.council() != council_) revert RegistryMismatch(); // GUARD(token-council-match)
        compliance = compliance_;
        registry = registry_;
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC7943Fungible).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ----- minting (the M2 CreditPool will hold MINTER_ROLE) -----

    // GUARD(token-mint-role)
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount); // GUARD(path-mint)
    }

    // GUARD(token-batch-mint-role)
    function batchMint(address[] calldata to, uint256[] calldata amounts) external onlyRole(MINTER_ROLE) {
        _checkBatch(to.length, amounts.length);
        for (uint256 i = 0; i < to.length; ++i) {
            _mint(to[i], amounts[i]); // GUARD(path-batch-mint)
        }
    }

    // ----- holder paths -----

    /// Many transfers from the caller, all or nothing. OPEN(holder)
    function batchTransfer(address[] calldata to, uint256[] calldata amounts) external returns (bool) {
        _checkBatch(to.length, amounts.length);
        for (uint256 i = 0; i < to.length; ++i) {
            _transfer(msg.sender, to[i], amounts[i]); // GUARD(path-batch-transfer)
        }
        return true;
    }

    // ----- emergency controls: protective at once, release by the council -----

    // GUARD(token-pause-role)
    function pause() external onlyRoleOrCouncil(AGENT_ROLE) {
        paused = true;
        emit Paused(msg.sender);
    }

    // GUARD(token-unpause-council)
    function unpause() external onlyCouncil {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// ERC-7943. Raising the frozen amount protects, so an agent may do it; lowering it
    /// releases tokens and is the council's. AUTH(body)
    function setFrozenTokens(address account, uint256 amount) external returns (bool) {
        if (amount < _frozenTokens[account]) {
            _onlyCouncil(); // GUARD(token-unfreeze-council)
        } else {
            _onlyRoleOrCouncil(AGENT_ROLE); // GUARD(token-freeze-role)
        }
        _setFrozen(account, amount);
        return true;
    }

    // ----- council-only moves of a holder's tokens -----

    /// ERC-7943. Skips the sender's rules and the frozen amount (the unfrozen part moves
    /// first; only the rest is released, with a `Frozen` event), never the receiver's. The
    /// council's proposal records the reason.
    // GUARD(token-forced-council)
    function forcedTransfer(address from, address to, uint256 amount) external onlyCouncil returns (bool) {
        if (from == to) revert SameWallet(); // GUARD(forced-same-wallet)
        uint256 balance = balanceOf(from);
        if (amount > balance) revert ERC20InsufficientBalance(from, balance, amount);
        _releaseFrozen(from, balance, amount);
        _forcing = true;
        _transfer(from, to, amount); // GUARD(path-forced)
        _forcing = false;
        emit ForcedTransfer(from, to, amount);
        return true;
    }

    /// Moves a lost wallet's whole balance, frozen part included, to a new wallet of the
    /// same investor; the new wallet must pass every receiver rule. The proposal names the
    /// investor id, and both wallets must carry it when the call executes.
    // GUARD(token-recover-council)
    function recoverWallet(address lost, address replacement, bytes32 investorId) external onlyCouncil returns (bool) {
        if (lost == replacement) revert SameWallet(); // GUARD(recover-same-wallet)
        if (registry.investorIdOf(lost) != investorId) revert NotSameInvestor(lost, replacement); // GUARD(recover-expected-investor)
        if (investorId == bytes32(0) || investorId != registry.investorIdOf(replacement)) {
            revert NotSameInvestor(lost, replacement); // GUARD(recover-same-investor)
        }
        uint256 amount = balanceOf(lost);
        if (amount == 0) revert NothingToRecover(lost);
        uint256 frozen = _releaseFrozen(lost, amount, amount);
        _forcing = true;
        _transfer(lost, replacement, amount); // GUARD(path-recover)
        _forcing = false;
        if (frozen != 0) _setFrozen(replacement, _frozenTokens[replacement] + frozen);
        emit ForcedTransfer(lost, replacement, amount);
        emit WalletRecovered(lost, replacement, amount);
        return true;
    }

    // ----- ERC-7943 views -----

    function canSend(address account) external view returns (bool) {
        return compliance.partyRefusal(account, true) == Refusal.None;
    }

    function canReceive(address account) external view returns (bool) {
        return compliance.partyRefusal(account, false) == Refusal.None;
    }

    function getFrozenTokens(address account) external view returns (uint256) {
        return _frozenTokens[account];
    }

    /// More than the balance is always more than the unfrozen amount, which ERC-7943 says
    /// canTransfer MUST check, so it returns false (docs/DECISIONS.md D-005).
    function canTransfer(address from, address to, uint256 amount) external view returns (bool) {
        (Refusal r,) = _refusal(from, to, amount, false);
        return r == Refusal.None;
    }

    /// Which rule would refuse this transfer now (`None` if none would).
    function transferRefusal(address from, address to, uint256 amount) external view returns (Refusal r) {
        (r,) = _refusal(from, to, amount, false);
    }

    // ----- the one hook every balance change passes through -----

    function _update(address from, address to, uint256 value) internal override {
        (Refusal r, uint256 holdersAfter) = _refusal(from, to, value, _forcing);
        if (r != Refusal.None) _revertRefusal(from, to, value, r); // GUARD(token-hook)
        holderCount = holdersAfter;
        super._update(from, to, value);
    }

    function _refusal(address from, address to, uint256 value, bool forced)
        private
        view
        returns (Refusal, uint256 holdersAfter)
    {
        holdersAfter = holderCount;
        if (paused && !forced) return (Refusal.Paused, holdersAfter); // GUARD(paused)
        uint256 toBalance = balanceOf(to);
        uint256 fromAfter;
        if (from != address(0)) {
            uint256 fromBalance = balanceOf(from);
            if (value > fromBalance) return (Refusal.InsufficientBalance, holdersAfter);
            if (!forced && value > _unfrozen(from, fromBalance)) return (Refusal.FrozenTokens, holdersAfter); // GUARD(frozen-tokens)
            fromAfter = fromBalance - value;
        }
        uint256 toAfter = toBalance;
        bool newHolder;
        if (from == to) {
            fromAfter = toBalance;
        } else if (value != 0) {
            toAfter = toBalance + value;
            if (toBalance == 0) {
                newHolder = true;
                ++holdersAfter;
            }
            if (from != address(0) && fromAfter == 0) --holdersAfter;
        }
        Refusal r = compliance.transferRefusal(from, to, fromAfter, toAfter, holdersAfter, newHolder, forced);
        return (r, holdersAfter);
    }

    function _setFrozen(address account, uint256 amount) private {
        _frozenTokens[account] = amount;
        emit Frozen(account, amount);
        emit FrozenTokensChanged(account, amount, msg.sender);
    }

    /// Before a council move of `amount` out of `balance`: the unfrozen part goes first and
    /// only the rest of `amount` is released from the frozen amount, which it returns.
    function _releaseFrozen(address from, uint256 balance, uint256 amount) private returns (uint256 released) {
        uint256 frozen = _frozenTokens[from];
        uint256 unfrozen = balance > frozen ? balance - frozen : 0;
        if (amount > unfrozen) {
            released = amount - unfrozen;
            _setFrozen(from, frozen - released); // GUARD(frozen-release)
        }
    }

    function _unfrozen(address account, uint256 balance) private view returns (uint256) {
        uint256 frozen = _frozenTokens[account];
        return frozen >= balance ? 0 : balance - frozen;
    }

    function _revertRefusal(address from, address to, uint256 value, Refusal r) private view {
        if (r == Refusal.InsufficientBalance) revert ERC20InsufficientBalance(from, balanceOf(from), value);
        if (r == Refusal.FrozenTokens) {
            revert ERC7943InsufficientUnfrozenBalance(from, value, _unfrozen(from, balanceOf(from)));
        }
        revert TransferRefused(from, to, value, r);
    }

    function _checkBatch(uint256 toLength, uint256 amountsLength) private pure {
        if (toLength != amountsLength) revert LengthMismatch();
        if (toLength > MAX_BATCH) revert BatchTooLarge(toLength); // GUARD(batch-bound)
    }
}
