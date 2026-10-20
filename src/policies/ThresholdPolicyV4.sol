// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ILexifiPolicy} from "../interfaces/ILexifiPolicy.sol";
import {IVerificationProvider} from "../interfaces/IVerificationProvider.sol";
import {LexifiPolicyConfig} from "../LexifiPolicyConfig.sol";
import {LexifiSwapAmount} from "../libraries/LexifiSwapAmount.sol";

/// @title ThresholdPolicyV4
/// @notice ThresholdPolicyV3 with limits per currency (Olympix finding 3, unit mismatch).
///
/// @dev **What changed from ThresholdPolicyV3.** V3 compared the swap amount against one
///      `noKycLimit` / `enhancedLimit` pair without knowing which token the amount was in. The
///      hook passed `|amountSpecified|`, and the swapper chooses, through `zeroForOne` and
///      exact-in/exact-out, whether that is a currency0 or a currency1 amount. With limits in
///      18-decimal units on a TOKEN/USDC pool, 1e14 (documented as "0.0001 ETH") read as
///      100,000,000 USDC when stated on the USDC side, and the KYC gate was void.
///
///      V4 stores a pair of limits for each currency and reads the currency from the amount
///      (`LexifiSwapAmount`: bit 255 set = currency1). LexifiHookV4 encodes it from the swap
///      params. A plain amount with bit 255 clear is read as currency0, which is the meaning
///      `ILexifiPolicy` has always documented ("in token0 terms"), so integrators that pass a
///      currency0 number need no change.
///
///      **Use with LexifiHookV4.** LexifiHook and LexifiHookV3 do not set the flag, so every
///      swap would be read as currency0 and the bypass would remain on the currency1 side.
///
///      Limits are in each token's own base units, so no price oracle is involved and nothing
///      can be moved by manipulating the pool. The cost: the two limits are set at one price,
///      and if the price moves a long way the bands drift apart. Issuers re-set the config,
///      or set both sides conservatively. To require verification for every swap stated in
///      one currency, set that currency's `noKycLimit` to 0.
///
///      Kept from V3: fail-closed on unconfigured pools; no owner and no override; unverified
///      results count as DENIED; LP minimum clamped up to the swap minimum; the swap minimum
///      enforced at no less than RETAIL (`_swapFloor`, finding 1). The layout changed, so V4
///      uses a new `CONFIG_FAMILY`: a V3 config is not read as a V4 one.
contract ThresholdPolicyV4 is ILexifiPolicy {
    struct ThresholdConfig {
        uint256 noKycLimit0; // currency0 base units: swaps at or below this pass for anyone
        uint256 enhancedLimit0; // currency0 base units: above this needs ACCREDITED
        uint256 noKycLimit1; // currency1 base units
        uint256 enhancedLimit1; // currency1 base units
        AccessLevel lpMinimum; // Minimum for adding liquidity (clamped to >= swapMinimum)
        AccessLevel swapMinimum; // Minimum for swaps above the no-KYC limit
        bool active;
    }

    /// @notice New family: the V3 single-limit layout does not decode as this one.
    bytes32 public constant CONFIG_FAMILY = keccak256("lexifi.policy.threshold.percurrency");

    IVerificationProvider public immutable provider;
    LexifiPolicyConfig public immutable configRegistry;

    error ZeroAddress();

    constructor(address _provider, address _registry) {
        if (_provider == address(0) || _registry == address(0)) revert ZeroAddress();
        provider = IVerificationProvider(_provider);
        configRegistry = LexifiPolicyConfig(_registry);
    }

    /// @dev Decode config and normalise it. `configured` false means "deny", never "allow".
    function _config(PoolId poolId)
        internal
        view
        returns (ThresholdConfig memory cfg, bool configured)
    {
        bytes memory raw = configRegistry.getConfig(CONFIG_FAMILY, poolId);
        if (raw.length == 0) return (cfg, false);
        cfg = abi.decode(raw, (ThresholdConfig));
        if (!cfg.active) return (cfg, false);

        if (uint8(cfg.lpMinimum) < uint8(cfg.swapMinimum)) {
            cfg.lpMinimum = cfg.swapMinimum;
        }
        configured = true;
    }

    /// @param amount For swaps, a `LexifiSwapAmount` encoding (bit 255 = currency1). For
    ///        liquidity, the hook's `liquidityDelta`; it is not used.
    function checkAccess(PoolId poolId, address user, uint8 operation, uint256 amount)
        external
        view
        override
        returns (AccessLevel level, string memory reason)
    {
        (ThresholdConfig memory cfg, bool configured) = _config(poolId);
        if (!configured) return (AccessLevel.DENIED, "Pool not configured for this policy");

        uint256 magnitude;
        uint256 noKycLimit;
        uint256 enhancedLimit;
        if (operation == 0) {
            bool inCurrency1;
            (magnitude, inCurrency1) = LexifiSwapAmount.decode(amount);
            (noKycLimit, enhancedLimit) = inCurrency1
                ? (cfg.noKycLimit1, cfg.enhancedLimit1)
                : (cfg.noKycLimit0, cfg.enhancedLimit0);

            if (magnitude <= noKycLimit) {
                // Small trade, measured in the token it is stated in: anyone can swap.
                return (AccessLevel.INSTITUTIONAL, "");
            }
        }

        IVerificationProvider.VerificationResult memory v = provider.verify(user);
        level = v.verified ? AccessLevel(v.tier) : AccessLevel.DENIED;

        if (operation == 0) {
            if (magnitude > enhancedLimit && uint8(level) < uint8(AccessLevel.ACCREDITED)) {
                return (AccessLevel.DENIED, "Large trade requires enhanced verification");
            }
            if (uint8(level) < uint8(cfg.swapMinimum)) {
                return (AccessLevel.DENIED, "Swap requires basic verification");
            }
            AccessLevel floor = _swapFloor(cfg);
            if (uint8(level) < uint8(floor)) level = floor;
        } else if (operation == 1) {
            if (uint8(level) < uint8(cfg.lpMinimum)) {
                return (AccessLevel.DENIED, "Liquidity provision requires verification");
            }
        }

        return (level, "");
    }

    function minimumLevel(PoolId poolId, uint8 operation)
        external
        view
        override
        returns (AccessLevel)
    {
        (ThresholdConfig memory cfg, bool configured) = _config(poolId);
        if (!configured) return AccessLevel.INSTITUTIONAL;

        if (operation == 0) return _swapFloor(cfg);
        if (operation == 1) return cfg.lpMinimum;
        return AccessLevel.DENIED; // removeLiquidity: exit is never gated
    }

    /// @dev As in ThresholdPolicyV3: swaps have a deny path (above the enhanced limit) that
    ///      does not depend on `swapMinimum`, so the enforced swap minimum is never below RETAIL.
    function _swapFloor(ThresholdConfig memory cfg) internal pure returns (AccessLevel) {
        return uint8(cfg.swapMinimum) < uint8(AccessLevel.RETAIL) ? AccessLevel.RETAIL : cfg.swapMinimum;
    }

    function policyName() external pure override returns (string memory) {
        return "Lexifi Threshold Policy";
    }

    /// @dev v4 = V3 + per-currency limits read from a currency-tagged amount (finding 3).
    function policyVersion() external pure override returns (uint256) {
        return 4;
    }

    // ═══════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════

    /// @notice Encode a config for the registry's `setConfig`. Limits are in each currency's
    ///         own base units (e.g. 1e14 wei of ETH, 1e6 for 1 USDC).
    function encodeConfig(
        uint256 noKycLimit0,
        uint256 enhancedLimit0,
        uint256 noKycLimit1,
        uint256 enhancedLimit1,
        AccessLevel lpMinimum,
        AccessLevel swapMinimum
    ) external pure returns (bytes memory) {
        return abi.encode(
            ThresholdConfig({
                noKycLimit0: noKycLimit0,
                enhancedLimit0: enhancedLimit0,
                noKycLimit1: noKycLimit1,
                enhancedLimit1: enhancedLimit1,
                lpMinimum: lpMinimum,
                swapMinimum: swapMinimum,
                active: true
            })
        );
    }

    /// @notice The `amount` LexifiHookV4 passes for a swap, for off-chain previews and for
    ///         integrators calling `checkAccess` or the compliance adapter directly.
    function encodeSwapAmount(bool zeroForOne, int256 amountSpecified)
        external
        pure
        returns (uint256)
    {
        return LexifiSwapAmount.encode(zeroForOne, amountSpecified);
    }

    /// @notice Read back the effective config, after the LP clamp.
    function effectiveConfig(PoolId poolId)
        external
        view
        returns (ThresholdConfig memory cfg, bool configured)
    {
        return _config(poolId);
    }

    /// @notice True when the stored config needs no normalisation: the LP clamp is a no-op
    ///         and each currency's `enhancedLimit >= noKycLimit`.
    function validateConfig(PoolId poolId) external view returns (bool) {
        bytes memory raw = configRegistry.getConfig(CONFIG_FAMILY, poolId);
        if (raw.length == 0) return false;
        ThresholdConfig memory cfg = abi.decode(raw, (ThresholdConfig));
        return uint8(cfg.lpMinimum) >= uint8(cfg.swapMinimum)
            && cfg.enhancedLimit0 >= cfg.noKycLimit0 && cfg.enhancedLimit1 >= cfg.noKycLimit1;
    }
}
