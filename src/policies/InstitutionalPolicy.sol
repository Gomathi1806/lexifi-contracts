// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ILexifiPolicy} from "../interfaces/ILexifiPolicy.sol";
import {IVerificationProvider} from "../interfaces/IVerificationProvider.sol";

/// @title InstitutionalPolicy
/// @notice "Pool B" — Institutional-only pools requiring multiple verifications.
/// @dev For high-value RWA pools, security token pools, or institutional DeFi.
///      Supports multiple verification providers (e.g., Coinbase + ZK-proof of accreditation).
///      Pool creator can require N-of-M providers to agree.
///
///      Use cases:
///      - Security token trading pools (SEC/MiFID compliant)
///      - RWA tokenized bond pools (accredited investors only)
///      - Institutional OTC pools (business verification required)
contract InstitutionalPolicy is ILexifiPolicy {
    struct InstitutionalConfig {
        address[] requiredProviders;  // All providers that must verify
        uint256 minimumProviders;     // Minimum number that must pass (N of M)
        AccessLevel minimumTier;      // Minimum tier from each provider
        bool active;
    }

    /// @notice Per-pool institutional configuration
    mapping(PoolId => InstitutionalConfig) internal _configs;
    mapping(PoolId => address) public poolAdmins;

    address public owner;

    error Unauthorized();
    error TooFewProviders();

    constructor(address _owner) {
        owner = _owner;
    }

    function checkAccess(
        PoolId poolId,
        address user,
        uint8 /* operation */,
        uint256 /* amount */
    ) external view override returns (AccessLevel level, string memory reason) {
        InstitutionalConfig storage cfg = _configs[poolId];
        if (!cfg.active) return (AccessLevel.INSTITUTIONAL, "");

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
            return (
                AccessLevel(highestTier),
                "Insufficient institutional verifications"
            );
        }

        return (AccessLevel(highestTier), "");
    }

    function minimumLevel(
        PoolId poolId,
        uint8 /* operation */
    ) external view override returns (AccessLevel) {
        InstitutionalConfig storage cfg = _configs[poolId];
        if (!cfg.active) return AccessLevel.DENIED;
        return cfg.minimumTier;
    }

    function policyName() external pure override returns (string memory) {
        return "Lexifi Institutional Policy";
    }

    function policyVersion() external pure override returns (uint256) {
        return 1;
    }

    /// @notice Configure institutional requirements for a pool
    /// @param providers List of verification provider contracts
    /// @param minProviders Minimum providers that must verify (N of M)
    /// @param minTier Minimum tier each provider must return
    function setInstitutionalConfig(
        PoolId poolId,
        address[] calldata providers,
        uint256 minProviders,
        AccessLevel minTier
    ) external {
        if (providers.length == 0) revert TooFewProviders();
        if (minProviders > providers.length) revert TooFewProviders();
        if (poolAdmins[poolId] != address(0) && poolAdmins[poolId] != msg.sender) {
            revert Unauthorized();
        }

        _configs[poolId] = InstitutionalConfig({
            requiredProviders: providers,
            minimumProviders: minProviders,
            minimumTier: minTier,
            active: true
        });

        if (poolAdmins[poolId] == address(0)) {
            poolAdmins[poolId] = msg.sender;
        }
    }

    /// @notice Get pool config (since arrays can't be returned from public mapping)
    function getConfig(PoolId poolId) external view returns (
        address[] memory providers,
        uint256 minProviders,
        AccessLevel minTier,
        bool active
    ) {
        InstitutionalConfig storage cfg = _configs[poolId];
        return (cfg.requiredProviders, cfg.minimumProviders, cfg.minimumTier, cfg.active);
    }
}
