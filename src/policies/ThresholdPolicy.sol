// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ILexifiPolicy} from "../interfaces/ILexifiPolicy.sol";
import {IVerificationProvider} from "../interfaces/IVerificationProvider.sol";

/// @title ThresholdPolicy
/// @notice "Pool A" — Retail-friendly compliance with amount-based thresholds.
/// @dev Example rules a DEX might configure:
///      - Swaps under $1,000: No KYC required (RETAIL tier not needed)
///      - Swaps $1,000-$10,000: Basic KYC required (RETAIL tier)
///      - Swaps over $10,000: Enhanced verification (ACCREDITED tier)
///      - Adding liquidity: Always requires RETAIL minimum
///
///      Pool creators set thresholds via setPoolConfig(). This allows each pool
///      on the same DEX to have different compliance requirements.
contract ThresholdPolicy is ILexifiPolicy {
    struct PoolConfig {
        uint256 noKycLimit; // Below this amount: no KYC needed
        uint256 enhancedLimit; // Above this: requires ACCREDITED
        AccessLevel lpMinimum; // Minimum for liquidity providers
        AccessLevel swapMinimum; // Minimum for any swap (floor)
        bool active;
    }

    /// @notice Configuration per pool
    mapping(PoolId => PoolConfig) public configs;

    /// @notice Who can configure each pool (set by pool admin via hook)
    mapping(PoolId => address) public poolAdmins;

    /// @notice Verification provider to query
    IVerificationProvider public immutable provider;

    /// @notice Manual overrides (for testing/emergency)
    mapping(address => AccessLevel) public overrides;

    /// @notice Policy deployer
    address public owner;

    error Unauthorized();

    constructor(address _provider, address _owner) {
        provider = IVerificationProvider(_provider);
        owner = _owner;
    }

    // ═══════════════════════════════════════════
    //  ILexifiPolicy
    // ═══════════════════════════════════════════

    function checkAccess(
        PoolId poolId,
        address user,
        uint8 operation,
        uint256 amount
    ) external view override returns (AccessLevel level, string memory reason) {
        // Check manual override first
        if (overrides[user] != AccessLevel.DENIED) {
            return (overrides[user], "");
        }

        // Get user's verification level from provider
        IVerificationProvider.VerificationResult memory v = provider.verify(
            user
        );
        level = AccessLevel(v.tier);

        PoolConfig memory cfg = configs[poolId];

        if (!cfg.active) {
            // Pool not configured — default open
            return (AccessLevel.INSTITUTIONAL, "");
        }

        // For swaps: amount-based threshold logic
        if (operation == 0) {
            if (amount <= cfg.noKycLimit) {
                // Small trade — anyone can swap
                return (AccessLevel.INSTITUTIONAL, "");
            }
            if (
                amount > cfg.enhancedLimit &&
                uint8(level) < uint8(AccessLevel.ACCREDITED)
            ) {
                return (
                    AccessLevel.DENIED,
                    "Large trade requires enhanced verification"
                );
            }
            if (uint8(level) < uint8(cfg.swapMinimum)) {
                return (AccessLevel.DENIED, "Swap requires basic verification");
            }
        }

        // For adding liquidity
        if (operation == 1) {
            if (uint8(level) < uint8(cfg.lpMinimum)) {
                return (
                    AccessLevel.DENIED,
                    "Liquidity provision requires verification"
                );
            }
        }

        // operation == 2 (removeLiquidity) should never reach here
        // because the hook doesn't call policy for exits

        return (level, "");
    }

    function minimumLevel(
        PoolId poolId,
        uint8 operation
    ) external view override returns (AccessLevel) {
        PoolConfig memory cfg = configs[poolId];
        if (!cfg.active) return AccessLevel.DENIED; // Open pool

        if (operation == 0) return cfg.swapMinimum;
        if (operation == 1) return cfg.lpMinimum;
        return AccessLevel.DENIED; // removeLiquidity: no minimum
    }

    function policyName() external pure override returns (string memory) {
        return "Lexifi Threshold Policy";
    }

    function policyVersion() external pure override returns (uint256) {
        return 1;
    }

    // ═══════════════════════════════════════════
    //  CONFIGURATION
    // ═══════════════════════════════════════════

    /// @notice Configure compliance thresholds for a pool
    /// @dev Called by the pool admin (DEX operator)
    function setPoolConfig(
        PoolId poolId,
        uint256 noKycLimit,
        uint256 enhancedLimit,
        AccessLevel lpMinimum,
        AccessLevel swapMinimum
    ) external {
        // First time: anyone can set (hook will set admin). After: only admin.
        if (
            poolAdmins[poolId] != address(0) && poolAdmins[poolId] != msg.sender
        ) {
            revert Unauthorized();
        }

        configs[poolId] = PoolConfig({
            noKycLimit: noKycLimit,
            enhancedLimit: enhancedLimit,
            lpMinimum: lpMinimum,
            swapMinimum: swapMinimum,
            active: true
        });

        if (poolAdmins[poolId] == address(0)) {
            poolAdmins[poolId] = msg.sender;
        }
    }

    /// @notice Set a manual override for a user (testing/emergency)
    function setOverride(address user, AccessLevel level) external {
        if (msg.sender != owner) revert Unauthorized();
        overrides[user] = level;
    }

    /// @notice Transfer pool admin
    function transferPoolAdmin(PoolId poolId, address newAdmin) external {
        if (poolAdmins[poolId] != msg.sender) revert Unauthorized();
        poolAdmins[poolId] = newAdmin;
    }
}
