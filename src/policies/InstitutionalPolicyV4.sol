// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ILexifiPolicy} from "../interfaces/ILexifiPolicy.sol";
import {IVerificationProvider} from "../interfaces/IVerificationProvider.sol";
import {LexifiPolicyConfig} from "../LexifiPolicyConfig.sol";

/// @title InstitutionalPolicyV4
/// @notice InstitutionalPolicyV3 with the Olympix finding 1 fix: a failed quorum always denies.
///
/// @dev **What changed from InstitutionalPolicyV3.** V3 returned the stored `minimumTier` from
///      `minimumLevel` as is. A failed quorum returns DENIED (0), and enforcement is
///      `level >= minimumLevel`, so with `minimumTier = DENIED` ("verified by N providers, at
///      any tier") a wallet with no verification at all compared `0 >= 0` and passed: the
///      N-of-M quorum gated nothing.
///
///      V4 floors the enforced minimum at RETAIL for every configured pool, as
///      RegionalPolicyV4 and ThresholdPolicyV3 do. A user who meets the quorum is lifted to the
///      floor if their highest passing tier is below it (only possible when the stored minimum
///      is DENIED), so the quorum still means "verified by N providers, at any tier".
///
///      Also: `minimumLevel` now returns DENIED for operation 2 (remove liquidity), like the
///      other policies. V3 returned `minimumTier` for every operation. The hook never checks
///      removal, so this changes no enforcement; it keeps the "exit is never gated" invariant
///      true for any caller of the policy.
///
///      Same `CONFIG_FAMILY` and layout as V3. Deploy against `LexifiPolicyConfigV2`.
contract InstitutionalPolicyV4 is ILexifiPolicy {
    struct InstitutionalConfig {
        address[] requiredProviders;
        uint256 minimumProviders;
        AccessLevel minimumTier;
        bool active;
    }

    /// @notice Same family as InstitutionalPolicyV3: the config layout is unchanged.
    bytes32 public constant CONFIG_FAMILY = keccak256("lexifi.policy.institutional");

    LexifiPolicyConfig public immutable configRegistry;

    error ZeroAddress();

    constructor(address _registry) {
        if (_registry == address(0)) revert ZeroAddress();
        configRegistry = LexifiPolicyConfig(_registry);
    }

    function _config(PoolId poolId)
        internal
        view
        returns (InstitutionalConfig memory cfg, bool configured)
    {
        bytes memory raw = configRegistry.getConfig(CONFIG_FAMILY, poolId);
        if (raw.length == 0) return (cfg, false);
        cfg = abi.decode(raw, (InstitutionalConfig));
        if (!cfg.active || cfg.requiredProviders.length == 0) return (cfg, false);

        // Unchanged from V3: 1 <= quorum <= provider count.
        if (cfg.minimumProviders > cfg.requiredProviders.length) {
            cfg.minimumProviders = cfg.requiredProviders.length;
        }
        if (cfg.minimumProviders == 0) cfg.minimumProviders = 1;

        configured = true;
    }

    function checkAccess(PoolId poolId, address user, uint8, /* operation */ uint256 /* amount */ )
        external
        view
        override
        returns (AccessLevel level, string memory reason)
    {
        (InstitutionalConfig memory cfg, bool configured) = _config(poolId);
        if (!configured) return (AccessLevel.DENIED, "Pool not configured for this policy");

        uint256 passed = 0;
        uint256 highestTier = 0;

        for (uint256 i = 0; i < cfg.requiredProviders.length; i++) {
            IVerificationProvider.VerificationResult memory v =
                IVerificationProvider(cfg.requiredProviders[i]).verify(user);

            if (v.verified && v.tier >= uint256(cfg.minimumTier)) {
                passed++;
                if (v.tier > highestTier) highestTier = v.tier;
            }
        }

        if (passed < cfg.minimumProviders) {
            return (AccessLevel.DENIED, "Insufficient institutional verifications");
        }

        // Quorum met, so highestTier >= minimumTier. Lift to the floor (see `_floor`).
        level = AccessLevel(highestTier);
        AccessLevel floor = _floor(cfg.minimumTier);
        if (uint8(level) < uint8(floor)) level = floor;
        return (level, "");
    }

    function minimumLevel(PoolId poolId, uint8 operation)
        external
        view
        override
        returns (AccessLevel)
    {
        (InstitutionalConfig memory cfg, bool configured) = _config(poolId);
        // Maximum, not DENIED: checkAccess returns DENIED here and `0 >= 0` would pass.
        if (!configured) return AccessLevel.INSTITUTIONAL;
        if (operation > 1) return AccessLevel.DENIED; // removeLiquidity: exit is never gated
        return _floor(cfg.minimumTier);
    }

    /// @dev The minimum as enforced: never below RETAIL, so a failed quorum (DENIED) always
    ///      fails the comparison.
    function _floor(AccessLevel stored) internal pure returns (AccessLevel) {
        return uint8(stored) < uint8(AccessLevel.RETAIL) ? AccessLevel.RETAIL : stored;
    }

    function policyName() external pure override returns (string memory) {
        return "Lexifi Institutional Policy";
    }

    /// @dev v4 = V3 + enforced minimum floored at RETAIL (Olympix finding 1).
    function policyVersion() external pure override returns (uint256) {
        return 4;
    }

    /// @notice Encode a config for the registry's `setConfig`. Same layout as V3.
    function encodeConfig(address[] calldata providers, uint256 minProviders, AccessLevel minTier)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(
            InstitutionalConfig({
                requiredProviders: providers,
                minimumProviders: minProviders,
                minimumTier: minTier,
                active: true
            })
        );
    }

    /// @notice Read back the config after quorum normalisation (stored tier, before the floor).
    function effectiveConfig(PoolId poolId)
        external
        view
        returns (InstitutionalConfig memory cfg, bool configured)
    {
        return _config(poolId);
    }
}
