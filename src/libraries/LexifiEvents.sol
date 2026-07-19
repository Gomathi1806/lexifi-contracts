// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title LexifiEvents
/// @notice Standardized compliance events for on-chain audit trails.
/// @dev DEXs and regulators can index these events for compliance reporting.
library LexifiEvents {
    /// @notice Emitted when a pool is initialized with a compliance policy
    event PoolPolicySet(
        PoolId indexed poolId,
        address indexed policyContract,
        string policyName,
        uint256 policyVersion,
        address indexed poolCreator
    );

    /// @notice Emitted when a compliance check passes
    event ComplianceCheckPassed(
        PoolId indexed poolId,
        address indexed user,
        uint8 operation,      // 0=swap, 1=addLiquidity, 2=removeLiquidity
        uint8 accessLevel,    // The user's verified level
        uint8 requiredLevel,  // The minimum level required
        uint256 amount,
        uint256 timestamp
    );

    /// @notice Emitted when a compliance check fails (before revert)
    event ComplianceCheckFailed(
        PoolId indexed poolId,
        address indexed user,
        uint8 operation,
        uint8 accessLevel,
        uint8 requiredLevel,
        string reason,
        uint256 timestamp
    );

    /// @notice Emitted when a pool's policy is updated
    event PoolPolicyUpdated(
        PoolId indexed poolId,
        address indexed oldPolicy,
        address indexed newPolicy,
        address updatedBy
    );

    /// @notice Emitted when a verification provider is added/removed from registry
    event ProviderRegistered(
        bytes32 indexed providerId,
        address indexed providerAddress,
        string providerName
    );

    event ProviderRevoked(
        bytes32 indexed providerId,
        address indexed providerAddress,
        string reason
    );

    /// @notice Emitted for every compliance-gated transaction (the core audit record)
    event AuditRecord(
        bytes32 indexed txHash,
        PoolId indexed poolId,
        address indexed user,
        uint8 operation,
        bool passed,
        uint256 amount,
        uint256 blockNumber,
        uint256 timestamp
    );
}
