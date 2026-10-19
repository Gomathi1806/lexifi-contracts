// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ILexifiPolicy} from "../interfaces/ILexifiPolicy.sol";
import {IVerificationProvider} from "../interfaces/IVerificationProvider.sol";
import {LexifiPolicyConfig} from "../LexifiPolicyConfig.sol";

/// @title ThresholdPolicyV3
/// @notice Amount-based compliance — stateless logic over the policy config registry.
///
/// @dev Behaviour differences from the deployed v1 (`0x75f4…4199`), all deliberate:
///
///      1. **No first-writer admin.** v1 kept its own `poolAdmins` map and gave a pool to
///         whoever called `setPoolConfig` first, including for a pool that did not exist yet.
///         Anyone watching for an issuer's pool could claim it, set open thresholds and lock
///         the issuer out. V3 holds no per-pool storage: config is read from the registry
///         under `CONFIG_FAMILY`. Deploy it against `LexifiPolicyConfigV2`, where only
///         `hook.poolAdmin(poolId)` (set by LexifiHookV3 at pool creation) may write.
///
///      2. **Unconfigured pools are DENIED, not open.** v1 returned `INSTITUTIONAL` for
///         `!active`, so a pool pointed at the policy but never configured traded freely.
///         Same fix as RegionalPolicyV3: DENIED from `checkAccess`, INSTITUTIONAL from
///         `minimumLevel`, so the comparison fails on both sides.
///
///      3. **No owner override.** v1 let its owner give any address any level in every pool,
///         ahead of the provider and the pool's own config. V3 has no owner and no override.
///
///      4. **Unverified results count as DENIED.** v1 used `tier` even when `verified` was
///         false. V3 treats an unverified result as level DENIED, as RegionalPolicyV3 does.
///
///      5. **`lpMinimum` is clamped up to `swapMinimum` on every read** (Finding 1, as in
///         RegionalPolicyV3), so an address barred from swapping above the no-KYC limit cannot
///         acquire the asset by minting a position instead.
///
///      6. **The large-trade check holds when `swapMinimum` is DENIED.** v1 denied large trades
///         from unaccredited users but reported `swapMinimum` as the requirement, so with
///         `swapMinimum = DENIED` the hook compared DENIED to DENIED and let them through. V3
///         reports at least RETAIL for swaps (`_swapFloor`). Found by `testFuzz_VerdictMatchesSpec`.
///
///      Kept from v1, by design: swaps at or below `noKycLimit` pass for everyone, while adding
///      liquidity always needs `lpMinimum`. `amount` is what the hook passes: the absolute
///      `amountSpecified`, so its token and decimals depend on swap direction and exact-in/out.
contract ThresholdPolicyV3 is ILexifiPolicy {
    struct ThresholdConfig {
        uint256 noKycLimit; // Swaps at or below this: anyone
        uint256 enhancedLimit; // Swaps above this: ACCREDITED or higher
        AccessLevel lpMinimum; // Minimum for adding liquidity (clamped to >= swapMinimum)
        AccessLevel swapMinimum; // Minimum for swaps above noKycLimit
        bool active;
    }

    /// @notice Stable across logic versions — this is what makes redeploys migration-free.
    bytes32 public constant CONFIG_FAMILY = keccak256("lexifi.policy.threshold");

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

        // Finding 1, enforced on every read because the registry cannot validate.
        if (uint8(cfg.lpMinimum) < uint8(cfg.swapMinimum)) {
            cfg.lpMinimum = cfg.swapMinimum;
        }
        configured = true;
    }

    function checkAccess(PoolId poolId, address user, uint8 operation, uint256 amount)
        external
        view
        override
        returns (AccessLevel level, string memory reason)
    {
        (ThresholdConfig memory cfg, bool configured) = _config(poolId);
        if (!configured) return (AccessLevel.DENIED, "Pool not configured for this policy");

        if (operation == 0 && amount <= cfg.noKycLimit) {
            // Small trade — anyone can swap.
            return (AccessLevel.INSTITUTIONAL, "");
        }

        IVerificationProvider.VerificationResult memory v = provider.verify(user);
        level = v.verified ? AccessLevel(v.tier) : AccessLevel.DENIED;

        if (operation == 0) {
            if (amount > cfg.enhancedLimit && uint8(level) < uint8(AccessLevel.ACCREDITED)) {
                return (AccessLevel.DENIED, "Large trade requires enhanced verification");
            }
            if (uint8(level) < uint8(cfg.swapMinimum)) {
                return (AccessLevel.DENIED, "Swap requires basic verification");
            }
            // Allowed. Lift to the swap floor so it clears `minimumLevel` (see `_swapFloor`).
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
        // Must be the maximum level, not DENIED: checkAccess returns DENIED for an unconfigured
        // pool, and `DENIED >= DENIED` would pass.
        if (!configured) return AccessLevel.INSTITUTIONAL;

        if (operation == 0) return _swapFloor(cfg);
        if (operation == 1) return cfg.lpMinimum;
        return AccessLevel.DENIED; // removeLiquidity: exit is never gated
    }

    /// @dev The swap minimum as enforced: `swapMinimum`, but never below RETAIL. Swaps have a
    ///      deny path that does not depend on `swapMinimum` (above `enhancedLimit`), and a
    ///      DENIED verdict only blocks when the minimum is above DENIED. v1 returned
    ///      `swapMinimum` as is, so with `swapMinimum = DENIED` the large-trade check was a
    ///      no-op: `DENIED >= DENIED` passed. Allowed swaps are lifted to this floor in
    ///      `checkAccess`, so raising the minimum blocks nothing that should pass.
    function _swapFloor(ThresholdConfig memory cfg) internal pure returns (AccessLevel) {
        return uint8(cfg.swapMinimum) < uint8(AccessLevel.RETAIL) ? AccessLevel.RETAIL : cfg.swapMinimum;
    }

    function policyName() external pure override returns (string memory) {
        return "Lexifi Threshold Policy";
    }

    /// @dev v1 = original (`0x75f4…4199`). v3 = registry-backed config, fail-closed
    ///      default, no owner override. Numbered 3 to match the other V3 policies; there is no v2.
    function policyVersion() external pure override returns (uint256) {
        return 3;
    }

    // ═══════════════════════════════════════════
    //  Config helpers — writes go to the registry, not here
    // ═══════════════════════════════════════════

    /// @notice Encode a config for the registry's `setConfig`.
    function encodeConfig(
        uint256 noKycLimit,
        uint256 enhancedLimit,
        AccessLevel lpMinimum,
        AccessLevel swapMinimum
    ) external pure returns (bytes memory) {
        return abi.encode(
            ThresholdConfig({
                noKycLimit: noKycLimit,
                enhancedLimit: enhancedLimit,
                lpMinimum: lpMinimum,
                swapMinimum: swapMinimum,
                active: true
            })
        );
    }

    /// @notice Read back the effective config, after the Finding-1 clamp.
    function effectiveConfig(PoolId poolId)
        external
        view
        returns (ThresholdConfig memory cfg, bool configured)
    {
        return _config(poolId);
    }

    /// @notice True when the stored config is already sane: the LP clamp is a no-op and
    ///         `enhancedLimit >= noKycLimit` (otherwise the enhanced band starts at noKycLimit).
    function validateConfig(PoolId poolId) external view returns (bool) {
        bytes memory raw = configRegistry.getConfig(CONFIG_FAMILY, poolId);
        if (raw.length == 0) return false;
        ThresholdConfig memory cfg = abi.decode(raw, (ThresholdConfig));
        return uint8(cfg.lpMinimum) >= uint8(cfg.swapMinimum)
            && cfg.enhancedLimit >= cfg.noKycLimit;
    }
}
