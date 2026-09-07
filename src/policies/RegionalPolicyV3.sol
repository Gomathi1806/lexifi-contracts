// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ILexifiPolicy} from "../interfaces/ILexifiPolicy.sol";
import {IVerificationProvider} from "../interfaces/IVerificationProvider.sol";
import {LexifiPolicyConfig} from "../LexifiPolicyConfig.sol";

/// @title RegionalPolicyV3
/// @notice Geographic compliance — stateless logic over LexifiPolicyConfig.
///
/// @dev Behaviour differences from the deployed v1 (`0xA99A…A44F`), all deliberate:
///
///      1. **Config lives in `LexifiPolicyConfig`, not here** (audit option C). Keyed by
///         `CONFIG_FAMILY`, which is constant across logic versions, so a future RegionalPolicy
///         v4 reads the same config and needs no migration. This contract holds no per-pool
///         storage at all.
///
///      2. **Unconfigured pools are DENIED, not open** (audit option D). v1 returned
///         `INSTITUTIONAL` for `!active`, which the hook's level comparison passed — so a pool
///         pointed at the policy but never configured traded freely. That turned a forgotten
///         migration into a silent compliance outage. It now fails closed and loudly.
///         (A pool with no policy at all is untouched — the hook never calls in.)
///
///      3. **Finding 1 fixed by read-time clamping, not config-time rejection.** The registry
///         stores opaque bytes and cannot validate, so this policy must not trust the stored
///         ordering. `minLp` is clamped up to `minSwap` on every read, which holds no matter how
///         the bytes got there. `validateConfig` is offered for callers that want to fail early.
///
///      4. **Finding 2 fixed.** The country and account branches return `DENIED` instead of the
///         user's real level, so the flags actually gate.
contract RegionalPolicyV3 is ILexifiPolicy {
    struct RegionConfig {
        bool requireCountryAttestation;
        bool requireAccountAttestation;
        AccessLevel minimumSwapLevel;
        AccessLevel minimumLpLevel;
        bool active;
    }

    /// @notice Stable across logic versions — this is what makes redeploys migration-free.
    bytes32 public constant CONFIG_FAMILY = keccak256("lexifi.policy.regional");

    IVerificationProvider public immutable provider;
    LexifiPolicyConfig public immutable configRegistry;

    address public owner;

    error ZeroAddress();

    constructor(address _provider, address _registry, address _owner) {
        if (_provider == address(0) || _registry == address(0) || _owner == address(0)) {
            revert ZeroAddress();
        }
        provider = IVerificationProvider(_provider);
        configRegistry = LexifiPolicyConfig(_registry);
        owner = _owner;
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

        // AUDIT FIX (Finding 1), enforced on every read because the registry cannot validate:
        // minLp below minSwap would let an address barred from buying the asset acquire it by
        // minting a position instead. Clamp rather than revert — a read path must not brick.
        if (uint8(cfg.minimumLpLevel) < uint8(cfg.minimumSwapLevel)) {
            cfg.minimumLpLevel = cfg.minimumSwapLevel;
        }
        configured = true;
    }

    function checkAccess(PoolId poolId, address user, uint8, /* operation */ uint256 /* amount */ )
        external
        view
        override
        returns (AccessLevel level, string memory reason)
    {
        (RegionConfig memory cfg, bool configured) = _config(poolId);
        // AUDIT FIX (option D): fail closed. v1 returned INSTITUTIONAL here.
        if (!configured) return (AccessLevel.DENIED, "Pool not configured for this policy");

        IVerificationProvider.VerificationResult memory v = provider.verify(user);
        level = AccessLevel(v.tier);

        if (!v.verified) return (AccessLevel.DENIED, "No verification found");

        // AUDIT FIX (Finding 2): DENIED, not the user's real level — the hook compares levels
        // and discards `reason`, so returning `level` made these flags no-ops.
        if (cfg.requireCountryAttestation && v.tier < 2) {
            return (AccessLevel.DENIED, "Country verification required for this pool");
        }
        if (cfg.requireAccountAttestation && v.tier < 1) {
            return (AccessLevel.DENIED, "Account verification required");
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
        // AUDIT FIX (option D) — this MUST be the maximum level, not DENIED.
        // Enforcement everywhere is `checkAccess().level >= minimumLevel(operation)`. An
        // unconfigured pool returns DENIED (0) from checkAccess, so returning DENIED here too
        // would make the comparison `0 >= 0` — which PASSES, admitting everyone. Requiring
        // INSTITUTIONAL against a DENIED level is what actually closes the pool.
        if (!configured) return AccessLevel.INSTITUTIONAL;

        if (operation == 0) return cfg.minimumSwapLevel;
        if (operation == 1) return cfg.minimumLpLevel;
        return AccessLevel.DENIED; // removeLiquidity: exit is never gated
    }

    function policyName() external pure override returns (string memory) {
        return "Lexifi Regional Policy";
    }

    /// @dev v1 = original (deployed 2026-07-21, buggy). v2 = audit fixes, self-stored config.
    ///      v3 = audit fixes + registry-backed config + fail-closed default.
    function policyVersion() external pure override returns (uint256) {
        return 3;
    }

    // ═══════════════════════════════════════════
    //  Config helpers — writes go to the registry, not here
    // ═══════════════════════════════════════════

    /// @notice Encode a config for `LexifiPolicyConfig.setConfig`.
    /// @dev Callers write through the registry directly; this only fixes the encoding so callers
    ///      cannot disagree with `_config` about the layout.
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

    /// @notice Read back the effective config, after the Finding-1 clamp.
    function effectiveConfig(PoolId poolId)
        external
        view
        returns (RegionConfig memory cfg, bool configured)
    {
        return _config(poolId);
    }

    /// @notice True when the stored ordering is already sane, i.e. the clamp is a no-op.
    /// @dev Lets a caller detect a config that would be silently tightened before committing it.
    function validateConfig(PoolId poolId) external view returns (bool) {
        bytes memory raw = configRegistry.getConfig(CONFIG_FAMILY, poolId);
        if (raw.length == 0) return false;
        RegionConfig memory cfg = abi.decode(raw, (RegionConfig));
        return uint8(cfg.minimumLpLevel) >= uint8(cfg.minimumSwapLevel);
    }
}
