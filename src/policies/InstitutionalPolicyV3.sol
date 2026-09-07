// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ILexifiPolicy} from "../interfaces/ILexifiPolicy.sol";
import {IVerificationProvider} from "../interfaces/IVerificationProvider.sol";
import {LexifiPolicyConfig} from "../LexifiPolicyConfig.sol";

/// @title InstitutionalPolicyV3
/// @notice N-of-M multi-provider verification — stateless logic over LexifiPolicyConfig.
///
/// @dev Behaviour differences from the deployed v1 (`0xaD09…b5fb`):
///
///      1. **Config lives in `LexifiPolicyConfig`** (option C), keyed by a `CONFIG_FAMILY` that
///         is constant across logic versions, so future redeploys need no migration.
///      2. **Unconfigured pools are DENIED, not open** (option D).
///      3. **Finding 3 fixed:** short of quorum returns `DENIED` instead of the user's tier.
///         v1 only raised `highestTier` for providers that PASSED, so a user cleared by one
///         provider came back at >= `minimumTier` and the hook's level comparison passed — a
///         1-of-3 user traded freely on a 2-of-3 pool, and the N-of-M quorum gated nothing.
///
///      Because the registry stores opaque bytes and cannot validate, `minimumProviders` is
///      clamped to the provider count at read time — a stored quorum larger than the provider
///      list would otherwise make the pool permanently unsatisfiable in a way no config-time
///      check could catch after the fact.
contract InstitutionalPolicyV3 is ILexifiPolicy {
    struct InstitutionalConfig {
        address[] requiredProviders;
        uint256 minimumProviders;
        AccessLevel minimumTier;
        bool active;
    }

    /// @notice Stable across logic versions.
    bytes32 public constant CONFIG_FAMILY = keccak256("lexifi.policy.institutional");

    LexifiPolicyConfig public immutable configRegistry;

    address public owner;

    error ZeroAddress();

    constructor(address _registry, address _owner) {
        if (_registry == address(0) || _owner == address(0)) revert ZeroAddress();
        configRegistry = LexifiPolicyConfig(_registry);
        owner = _owner;
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

        // The registry cannot validate, so normalise here: a quorum above the provider count
        // would be unsatisfiable forever. Clamping keeps it strict (all providers must pass)
        // rather than bricking the pool.
        if (cfg.minimumProviders > cfg.requiredProviders.length) {
            cfg.minimumProviders = cfg.requiredProviders.length;
        }
        // A zero quorum would make the policy a no-op; require at least one provider to pass.
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
        // AUDIT FIX (option D): fail closed. v1 returned INSTITUTIONAL here.
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

        // AUDIT FIX (Finding 3): DENIED, not AccessLevel(highestTier).
        if (passed < cfg.minimumProviders) {
            return (AccessLevel.DENIED, "Insufficient institutional verifications");
        }

        return (AccessLevel(highestTier), "");
    }

    function minimumLevel(PoolId poolId, uint8 /* operation */ )
        external
        view
        override
        returns (AccessLevel)
    {
        (InstitutionalConfig memory cfg, bool configured) = _config(poolId);
        // AUDIT FIX (option D) — maximum, not DENIED. Enforcement is
        // `checkAccess().level >= minimumLevel(operation)`; an unconfigured pool returns DENIED
        // from checkAccess, so returning DENIED here would make it `0 >= 0` and admit everyone.
        if (!configured) return AccessLevel.INSTITUTIONAL;
        return cfg.minimumTier;
    }

    function policyName() external pure override returns (string memory) {
        return "Lexifi Institutional Policy";
    }

    /// @dev v3 = audit fixes + registry-backed config + fail-closed default.
    function policyVersion() external pure override returns (uint256) {
        return 3;
    }

    /// @notice Encode a config for `LexifiPolicyConfig.setConfig`.
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

    /// @notice Read back the effective config, after normalisation.
    function effectiveConfig(PoolId poolId)
        external
        view
        returns (InstitutionalConfig memory cfg, bool configured)
    {
        return _config(poolId);
    }
}
