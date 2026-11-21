// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.30;

/// Why a balance move is refused. `None` means it is allowed. One code per rule, so a
/// refusal names the rule that stopped it.
enum Refusal {
    None,
    Paused,
    InsufficientBalance,
    FrozenTokens,
    SenderNotRegistered,
    SenderKycExpired,
    SenderFrozen,
    SenderCountryNotAllowed,
    LockUp,
    SenderBelowMinimumHolding,
    ReceiverNotRegistered,
    ReceiverKycExpired,
    ReceiverFrozen,
    ReceiverCountryNotAllowed,
    MaxHolders,
    ReceiverBelowMinimumHolding
}
