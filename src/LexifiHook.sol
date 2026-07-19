// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IMsgSender} from "v4-periphery/src/interfaces/IMsgSender.sol";
import {ILexifiPolicy} from "./interfaces/ILexifiPolicy.sol";
import {LexifiEvents} from "./libraries/LexifiEvents.sol";

contract LexifiHook is IHooks {
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;

    mapping(PoolId => address) public poolPolicy;
    mapping(PoolId => address) public poolAdmin;
    mapping(PoolId => bool) public isCompliancePool;
    address public owner;
    mapping(address => bool) public approvedPolicies;
    bool public requireApproval;
    uint256 public totalChecks;
    uint256 public totalPools;

    /// @notice Routers whose IMsgSender.msgSender() claim is honored for user identification.
    /// Only owner-vetted routers (e.g. Universal Router, PositionManager) may speak for a user;
    /// any other caller is compliance-checked as itself.
    mapping(address => bool) public trustedRouters;

    event TrustedRouterSet(address indexed router, bool trusted);

    error ComplianceDenied(address user, uint8 required, uint8 actual, string reason);
    error PolicyNotApproved(address policy);
    error InvalidPolicy(address policy);
    error NotPoolAdmin(address caller, PoolId poolId);
    error OnlyOwner();
    error OnlyPoolManager();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager, address _owner) {
        require(_owner != address(0), "zero owner");
        poolManager = _poolManager;
        owner = _owner;
        requireApproval = false;
    }

    function setPoolPolicy(PoolKey calldata key, address policy) external {
        PoolId poolId = key.toId();
        if (poolAdmin[poolId] != address(0) && poolAdmin[poolId] != msg.sender) {
            revert NotPoolAdmin(msg.sender, poolId);
        }
        if (policy == address(0)) revert InvalidPolicy(policy);
        if (requireApproval && !approvedPolicies[policy]) revert PolicyNotApproved(policy);
        try ILexifiPolicy(policy).policyName() returns (string memory) {} catch {
            revert InvalidPolicy(policy);
        }
        address oldPolicy = poolPolicy[poolId];
        poolPolicy[poolId] = policy;
        poolAdmin[poolId] = msg.sender;
        if (!isCompliancePool[poolId]) {
            isCompliancePool[poolId] = true;
            totalPools++;
            emit LexifiEvents.PoolPolicySet(poolId, policy, ILexifiPolicy(policy).policyName(), ILexifiPolicy(policy).policyVersion(), msg.sender);
        } else {
            emit LexifiEvents.PoolPolicyUpdated(poolId, oldPolicy, policy, msg.sender);
        }
    }

    // === IHooks: beforeInitialize (no hookData in this interface) ===
    function beforeInitialize(address, PoolKey calldata, uint160) external onlyPoolManager returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    // === IHooks: afterInitialize ===
    function afterInitialize(address, PoolKey calldata, uint160, int24) external onlyPoolManager returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    // === IHooks: beforeAddLiquidity ===
    function beforeAddLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata) external onlyPoolManager returns (bytes4) {
        PoolId poolId = key.toId();
        if (isCompliancePool[poolId]) {
            uint256 amount = params.liquidityDelta > 0 ? uint256(params.liquidityDelta) : 0;
            _enforceCompliance(poolId, _resolveUser(sender), 1, amount);
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    // === IHooks: afterAddLiquidity ===
    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    // === IHooks: beforeRemoveLiquidity (NEVER block exits) ===
    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external onlyPoolManager returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    // === IHooks: afterRemoveLiquidity ===
    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    // === IHooks: beforeSwap (compliance enforced here) ===
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        if (isCompliancePool[poolId]) {
            uint256 amount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            _enforceCompliance(poolId, _resolveUser(sender), 0, amount);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // === IHooks: afterSwap ===
    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata) external onlyPoolManager returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }

    // === IHooks: beforeDonate ===
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external onlyPoolManager returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    // === IHooks: afterDonate ===
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external onlyPoolManager returns (bytes4) {
        return IHooks.afterDonate.selector;
    }

    // === COMPLIANCE ENGINE ===

    /// @notice Resolve the end user behind a PoolManager call.
    /// @dev `sender` is the contract that called PoolManager (usually a router).
    ///      - Trusted routers (Universal Router, PositionManager, ...) expose the real
    ///        user via IMsgSender.msgSender(); works for EOAs, Safe multisigs, and
    ///        ERC-4337 smart accounts alike — msgSender() returns the account address.
    ///      - Any other caller is treated as the user itself, so an unvetted router
    ///        contract must hold its own verification (fail-safe: unverifiable => DENIED
    ///        by the policy, never falsely approved).
    ///      Never reads tx.origin.
    function _resolveUser(address sender) internal view returns (address) {
        if (trustedRouters[sender]) {
            try IMsgSender(sender).msgSender() returns (address user) {
                if (user != address(0)) return user;
            } catch {}
        }
        return sender;
    }

    function _enforceCompliance(PoolId poolId, address user, uint8 operation, uint256 amount) internal {
        address policy = poolPolicy[poolId];
        totalChecks++;
        (ILexifiPolicy.AccessLevel level, string memory reason) = ILexifiPolicy(policy).checkAccess(poolId, user, operation, amount);
        ILexifiPolicy.AccessLevel required = ILexifiPolicy(policy).minimumLevel(poolId, operation);
        if (uint8(level) < uint8(required)) {
            emit LexifiEvents.ComplianceCheckFailed(poolId, user, operation, uint8(level), uint8(required), reason, block.timestamp);
            emit LexifiEvents.AuditRecord(bytes32(0), poolId, user, operation, false, amount, block.number, block.timestamp);
            revert ComplianceDenied(user, uint8(required), uint8(level), reason);
        }
        emit LexifiEvents.ComplianceCheckPassed(poolId, user, operation, uint8(level), uint8(required), amount, block.timestamp);
        emit LexifiEvents.AuditRecord(bytes32(0), poolId, user, operation, true, amount, block.number, block.timestamp);
    }

    // === ADMIN ===
    function transferPoolAdmin(PoolKey calldata key, address newAdmin) external {
        PoolId poolId = key.toId();
        if (poolAdmin[poolId] != msg.sender) revert NotPoolAdmin(msg.sender, poolId);
        poolAdmin[poolId] = newAdmin;
    }

    function approvePolicy(address policy) external { if (msg.sender != owner) revert OnlyOwner(); approvedPolicies[policy] = true; }
    function revokePolicy(address policy) external { if (msg.sender != owner) revert OnlyOwner(); approvedPolicies[policy] = false; }
    function setRequireApproval(bool _require) external { if (msg.sender != owner) revert OnlyOwner(); requireApproval = _require; }
    function transferOwnership(address newOwner) external { if (msg.sender != owner) revert OnlyOwner(); require(newOwner != address(0), "zero owner"); owner = newOwner; }

    function setTrustedRouter(address router, bool trusted) external {
        if (msg.sender != owner) revert OnlyOwner();
        trustedRouters[router] = trusted;
        emit TrustedRouterSet(router, trusted);
    }

    // === VIEW ===
    function checkUserCompliance(PoolKey calldata key, address user, uint8 operation, uint256 amount) external view returns (bool allowed, uint8 userLevel, uint8 requiredLevel, string memory reason) {
        PoolId poolId = key.toId();
        if (!isCompliancePool[poolId]) return (true, 3, 0, "");
        address policy = poolPolicy[poolId];
        (ILexifiPolicy.AccessLevel level, string memory _reason) = ILexifiPolicy(policy).checkAccess(poolId, user, operation, amount);
        ILexifiPolicy.AccessLevel required = ILexifiPolicy(policy).minimumLevel(poolId, operation);
        return (uint8(level) >= uint8(required), uint8(level), uint8(required), _reason);
    }

    function getPoolInfo(PoolKey calldata key) external view returns (bool hasCompliance, address policy, string memory policyName, address admin) {
        PoolId poolId = key.toId();
        if (!isCompliancePool[poolId]) return (false, address(0), "", address(0));
        address _policy = poolPolicy[poolId];
        return (true, _policy, ILexifiPolicy(_policy).policyName(), poolAdmin[poolId]);
    }
}
