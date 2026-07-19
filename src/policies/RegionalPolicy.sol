// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ILexifiPolicy} from "../interfaces/ILexifiPolicy.sol";
import {IVerificationProvider} from "../interfaces/IVerificationProvider.sol";

/// @title RegionalPolicy
/// @notice "Pool C" — Geographic compliance for region-specific pools.
/// @dev Example: EU-regulated RWA pool that only allows EU-based users verified via EAS.
///      Pool creator specifies which verification schemas are required.
///      The policy checks both identity verification AND country attestation.
///
///      Use cases:
///      - EU MiCA-compliant pools (only EU residents)
///      - US accredited investor pools (SEC regulation)
///      - APAC pools excluding sanctioned jurisdictions
contract RegionalPolicy is ILexifiPolicy {
    struct RegionConfig {
        bool requireCountryAttestation; // Must have country verification
        bool requireAccountAttestation; // Must have account verification
        AccessLevel minimumSwapLevel;
        AccessLevel minimumLpLevel;
        bool active;
    }

    /// @notice Per-pool regional configuration
    mapping(PoolId => RegionConfig) public regionConfigs;
    mapping(PoolId => address) public poolAdmins;

    /// @notice Verification provider
    IVerificationProvider public immutable provider;

    address public owner;

    error Unauthorized();

    constructor(address _provider, address _owner) {
        require(_provider != address(0) && _owner != address(0), "zero address");
        provider = IVerificationProvider(_provider);
        owner = _owner;
    }

    function checkAccess(
        PoolId poolId,
        address user,
        uint8 operation,
        uint256 /* amount */
    ) external view override returns (AccessLevel level, string memory reason) {
        RegionConfig memory cfg = regionConfigs[poolId];
        if (!cfg.active) return (AccessLevel.INSTITUTIONAL, "");

        IVerificationProvider.VerificationResult memory v = provider.verify(user);
        level = AccessLevel(v.tier);

        if (!v.verified) {
            return (AccessLevel.DENIED, "No verification found");
        }

        // Check if country attestation is required but user only has account
        if (cfg.requireCountryAttestation && v.tier < 2) {
            return (level, "Country verification required for this pool");
        }

        if (cfg.requireAccountAttestation && v.tier < 1) {
            return (level, "Account verification required");
        }

        return (level, "");
    }

    function minimumLevel(
        PoolId poolId,
        uint8 operation
    ) external view override returns (AccessLevel) {
        RegionConfig memory cfg = regionConfigs[poolId];
        if (!cfg.active) return AccessLevel.DENIED;

        if (operation == 0) return cfg.minimumSwapLevel;
        if (operation == 1) return cfg.minimumLpLevel;
        return AccessLevel.DENIED;
    }

    function policyName() external pure override returns (string memory) {
        return "Lexifi Regional Policy";
    }

    function policyVersion() external pure override returns (uint256) {
        return 1;
    }

    /// @notice Configure regional requirements for a pool
    function setRegionConfig(
        PoolId poolId,
        bool requireCountry,
        bool requireAccount,
        AccessLevel minSwap,
        AccessLevel minLp
    ) external {
        if (poolAdmins[poolId] != address(0) && poolAdmins[poolId] != msg.sender) {
            revert Unauthorized();
        }

        regionConfigs[poolId] = RegionConfig({
            requireCountryAttestation: requireCountry,
            requireAccountAttestation: requireAccount,
            minimumSwapLevel: minSwap,
            minimumLpLevel: minLp,
            active: true
        });

        if (poolAdmins[poolId] == address(0)) {
            poolAdmins[poolId] = msg.sender;
        }
    }
}
