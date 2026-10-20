// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ILexifiPolicy} from "../interfaces/ILexifiPolicy.sol";
import {IVerificationProvider} from "../interfaces/IVerificationProvider.sol";
import {LexifiPolicyConfig} from "../LexifiPolicyConfig.sol";

/// @title RegionalPolicyV4
/// @notice RegionalPolicyV3 with the Olympix finding 1 fix: a DENIED verdict always denies.
///
/// @dev **What changed from RegionalPolicyV3.** V3 returned the stored `minimumSwapLevel` /
///      `minimumLpLevel` from `minimumLevel` as is. Every deny path in `checkAccess` (no
///      verification, country flag, account flag) signals denial by returning DENIED (0), and
///      enforcement is `level >= minimumLevel`. So with a stored minimum of DENIED, every
///      denial compared `0 >= 0` and passed: the attestation flags and the "verified" check
///      gated nothing.
///
///      V4 floors the enforced minimum at RETAIL for every configured pool (`_floor`), the
///      same fix as ThresholdPolicyV3's `_swapFloor`. A passing verdict below the floor (a
///      verified user at tier 0, in a pool whose stored minimum is DENIED) is lifted to the
///      floor, so a DENIED minimum keeps its meaning ("any verified user") and nothing that
///      should pass is blocked. Removal (operation 2) still requires DENIED: exits are never
///      gated.
///
///      Why a floor, not rejecting DENIED minimums: config is written to the registry as
///      opaque bytes, which this contract never sees, so it cannot reject anything at write
///      time. The only read-time alternative is to treat a DENIED minimum as unconfigured,
///      which would close pools whose admins meant "any verified user". The floor keeps those
///      pools working and makes denials hold.
///
///      Everything else is unchanged from V3: same `CONFIG_FAMILY` and layout (existing
///      configs read the same), fail-closed on unconfigured pools, LP minimum clamped up to the
///      swap minimum. Deploy against `LexifiPolicyConfigV2`.
contract RegionalPolicyV4 is ILexifiPolicy {
    struct RegionConfig {
        bool requireCountryAttestation;
        bool requireAccountAttestation;
        AccessLevel minimumSwapLevel;
        AccessLevel minimumLpLevel;
        bool active;
    }

    /// @notice Same family as RegionalPolicyV3: the config layout is unchanged.
    bytes32 public constant CONFIG_FAMILY = keccak256("lexifi.policy.regional");

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
        returns (RegionConfig memory cfg, bool configured)
    {
        bytes memory raw = configRegistry.getConfig(CONFIG_FAMILY, poolId);
        if (raw.length == 0) return (cfg, false);
        cfg = abi.decode(raw, (RegionConfig));
        if (!cfg.active) return (cfg, false);

        // V3 audit Finding 1, unchanged: LP minimum never below the swap minimum.
        if (uint8(cfg.minimumLpLevel) < uint8(cfg.minimumSwapLevel)) {
            cfg.minimumLpLevel = cfg.minimumSwapLevel;
        }
        configured = true;
    }

    function checkAccess(PoolId poolId, address user, uint8 operation, uint256 /* amount */ )
        external
        view
        override
        returns (AccessLevel level, string memory reason)
    {
        (RegionConfig memory cfg, bool configured) = _config(poolId);
        if (!configured) return (AccessLevel.DENIED, "Pool not configured for this policy");

        IVerificationProvider.VerificationResult memory v = provider.verify(user);
        if (!v.verified) return (AccessLevel.DENIED, "No verification found");

        if (cfg.requireCountryAttestation && v.tier < 2) {
            return (AccessLevel.DENIED, "Country verification required for this pool");
        }
        if (cfg.requireAccountAttestation && v.tier < 1) {
            return (AccessLevel.DENIED, "Account verification required");
        }

        level = AccessLevel(v.tier);
        // Allowed by every rule above. Lift to the enforced floor so a stored DENIED minimum
        // still admits verified tier-0 users (see `_floor`).
        if (operation <= 1) {
            AccessLevel floor = _floor(_storedMinimum(cfg, operation));
            if (uint8(level) >= uint8(_storedMinimum(cfg, operation)) && uint8(level) < uint8(floor)) {
                level = floor;
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
        (RegionConfig memory cfg, bool configured) = _config(poolId);
        // Maximum, not DENIED: checkAccess returns DENIED here and `0 >= 0` would pass.
        if (!configured) return AccessLevel.INSTITUTIONAL;
        if (operation <= 1) return _floor(_storedMinimum(cfg, operation));
        return AccessLevel.DENIED; // removeLiquidity: exit is never gated
    }

    function _storedMinimum(RegionConfig memory cfg, uint8 operation)
        internal
        pure
        returns (AccessLevel)
    {
        return operation == 0 ? cfg.minimumSwapLevel : cfg.minimumLpLevel;
    }

    /// @dev The minimum as enforced: never below RETAIL. A DENIED verdict only blocks when the
    ///      minimum is above DENIED, so this is what makes every deny path in `checkAccess`
    ///      hold regardless of the stored bytes.
    function _floor(AccessLevel stored) internal pure returns (AccessLevel) {
        return uint8(stored) < uint8(AccessLevel.RETAIL) ? AccessLevel.RETAIL : stored;
    }

    function policyName() external pure override returns (string memory) {
        return "Lexifi Regional Policy";
    }

    /// @dev v4 = V3 + enforced minimum floored at RETAIL (Olympix finding 1).
    function policyVersion() external pure override returns (uint256) {
        return 4;
    }

    // ═══════════════════════════════════════════
    //  Config helpers — writes go to the registry, not here
    // ═══════════════════════════════════════════

    /// @notice Encode a config for the registry's `setConfig`. Same layout as V3.
    function encodeConfig(
        bool requireCountry,
        bool requireAccount,
        AccessLevel minSwap,
        AccessLevel minLp
    ) external pure returns (bytes memory) {
        return abi.encode(
            RegionConfig({
                requireCountryAttestation: requireCountry,
                requireAccountAttestation: requireAccount,
                minimumSwapLevel: minSwap,
                minimumLpLevel: minLp,
                active: true
            })
        );
    }

    /// @notice Read back the config after the LP clamp (stored minimums, before the floor).
    function effectiveConfig(PoolId poolId)
        external
        view
        returns (RegionConfig memory cfg, bool configured)
    {
        return _config(poolId);
    }

    /// @notice True when the stored config needs no normalisation: LP minimum >= swap minimum
    ///         and neither minimum is DENIED (so the RETAIL floor is a no-op).
    function validateConfig(PoolId poolId) external view returns (bool) {
        bytes memory raw = configRegistry.getConfig(CONFIG_FAMILY, poolId);
        if (raw.length == 0) return false;
        RegionConfig memory cfg = abi.decode(raw, (RegionConfig));
        return uint8(cfg.minimumLpLevel) >= uint8(cfg.minimumSwapLevel)
            && cfg.minimumSwapLevel != AccessLevel.DENIED;
    }
}
