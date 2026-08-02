// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILexifiCompliance} from "./ILexifiCompliance.sol";
import {ILexifiPolicy} from "../interfaces/ILexifiPolicy.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title LexifiComplianceAdapter
/// @notice Bridges external hooks (Aqua0 V4Adapter, etc.) to Lexifi's policy system.
/// @dev Wraps the existing LexifiHook's policy registry into the single-call
///      ILexifiCompliance interface. Third-party hooks call checkCompliance()
///      in their beforeSwap — one STATICCALL, no state changes, no gas overhead
///      beyond the policy lookup itself.
///
///      Architecture:
///      ┌─────────────────────────┐
///      │  Aqua0 V4Adapter        │
///      │  (their hook)           │
///      │                         │
///      │  beforeSwap() {         │
///      │    ...validate JIT...   │
///      │    adapter.checkCompliance(poolId, user, 0, amount)  ← one call
///      │    ...inject JIT...     │
///      │  }                      │
///      └────────────┬────────────┘
///                   │ STATICCALL
///      ┌────────────▼────────────┐
///      │  LexifiComplianceAdapter │  (this contract)
///      │                         │
///      │  poolId → policy lookup │
///      │  policy.checkAccess()   │
///      │  policy.minimumLevel()  │
///      └────────────┬────────────┘
///                   │
///      ┌────────────▼────────────┐
///      │  ThresholdPolicy /      │
///      │  RegionalPolicy /       │
///      │  InstitutionalPolicy    │
///      │         ↓               │
///      │  CoinbaseEAS +          │
///      │  SelfAttestation        │
///      └─────────────────────────┘
contract LexifiComplianceAdapter is ILexifiCompliance {
    /// @notice The LexifiHook contract that holds the pool→policy registry
    address public immutable lexifiHook;

    constructor(address _lexifiHook) {
        require(_lexifiHook != address(0), "zero hook");
        lexifiHook = _lexifiHook;
    }

    /// @inheritdoc ILexifiCompliance
    function checkCompliance(
        bytes32 poolId,
        address user,
        uint8 operation,
        uint256 amount
    ) external view override returns (
        bool allowed,
        uint8 userTier,
        uint8 requiredTier,
        string memory reason
    ) {
        PoolId pid = PoolId.wrap(poolId);

        address policy = _getPoolPolicy(pid);
        if (policy == address(0)) {
            return (true, 3, 0, "");
        }

        (ILexifiPolicy.AccessLevel level, string memory _reason) =
            ILexifiPolicy(policy).checkAccess(pid, user, operation, amount);

        ILexifiPolicy.AccessLevel required =
            ILexifiPolicy(policy).minimumLevel(pid, operation);

        allowed = uint8(level) >= uint8(required);
        userTier = uint8(level);
        requiredTier = uint8(required);
        reason = _reason;
    }

    /// @inheritdoc ILexifiCompliance
    function hasPolicy(bytes32 poolId) external view override returns (bool) {
        PoolId pid = PoolId.wrap(poolId);
        return _isCompliancePool(pid);
    }

    function _getPoolPolicy(PoolId poolId) internal view returns (address) {
        // LexifiHook.poolPolicy(PoolId) → address
        (bool ok, bytes memory data) = lexifiHook.staticcall(
            abi.encodeWithSignature("poolPolicy(bytes32)", PoolId.unwrap(poolId))
        );
        if (!ok || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _isCompliancePool(PoolId poolId) internal view returns (bool) {
        (bool ok, bytes memory data) = lexifiHook.staticcall(
            abi.encodeWithSignature("isCompliancePool(bytes32)", PoolId.unwrap(poolId))
        );
        if (!ok || data.length < 32) return false;
        return abi.decode(data, (bool));
    }
}
