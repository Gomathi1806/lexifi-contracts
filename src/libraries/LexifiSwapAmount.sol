// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title LexifiSwapAmount
/// @notice Carries the currency of a swap amount inside the `amount` argument of
///         `ILexifiPolicy.checkAccess`, so the policy interface does not change.
/// @dev Olympix scan finding 3 ("unit mismatch"). LexifiHook and LexifiHookV3 pass only
///      `|amountSpecified|`. Whether that number is in currency0 or currency1 depends on
///      `zeroForOne` and on the sign (exact-in or exact-out), and the swapper picks both. A
///      threshold written in one token's units could therefore be bypassed by stating the
///      swap in the other token.
///
///      Encoding: bit 255 set means the amount is in currency1, clear means currency0. Clear
///      matches the documented meaning of `amount` in ILexifiPolicy ("in token0 terms"), so an
///      integrator that passes a plain number is read as currency0, as before.
///
///      The magnitude is saturated at `MAGNITUDE_MASK`. That only matters for
///      `amountSpecified == type(int256).min`, and saturating upward makes a check stricter,
///      never looser.
///
///      Which currency `amountSpecified` is in:
///
///      | zeroForOne | amountSpecified | meaning               | currency |
///      |------------|-----------------|-----------------------|----------|
///      | true       | < 0             | exact in, sell 0      | 0        |
///      | false      | < 0             | exact in, sell 1      | 1        |
///      | true       | > 0             | exact out, receive 1  | 1        |
///      | false      | > 0             | exact out, receive 0  | 0        |
///
///      So the amount is in currency1 exactly when `zeroForOne != exactIn`.
library LexifiSwapAmount {
    uint256 internal constant CURRENCY1_FLAG = 1 << 255;
    uint256 internal constant MAGNITUDE_MASK = CURRENCY1_FLAG - 1;

    /// @notice Encode a v4 swap's `(zeroForOne, amountSpecified)` for `checkAccess`.
    function encode(bool zeroForOne, int256 amountSpecified) internal pure returns (uint256) {
        bool exactIn = amountSpecified < 0;
        uint256 magnitude;
        if (amountSpecified == type(int256).min) magnitude = MAGNITUDE_MASK;
        else magnitude = uint256(exactIn ? -amountSpecified : amountSpecified);
        if (magnitude > MAGNITUDE_MASK) magnitude = MAGNITUDE_MASK;
        return zeroForOne != exactIn ? magnitude | CURRENCY1_FLAG : magnitude;
    }

    /// @notice Encode an amount already known to be in one currency.
    function encodeCurrency(uint256 magnitude, bool inCurrency1) internal pure returns (uint256) {
        if (magnitude > MAGNITUDE_MASK) magnitude = MAGNITUDE_MASK;
        return inCurrency1 ? magnitude | CURRENCY1_FLAG : magnitude;
    }

    /// @notice Split an encoded amount into its magnitude and currency.
    function decode(uint256 encoded) internal pure returns (uint256 magnitude, bool inCurrency1) {
        return (encoded & MAGNITUDE_MASK, encoded & CURRENCY1_FLAG != 0);
    }
}
