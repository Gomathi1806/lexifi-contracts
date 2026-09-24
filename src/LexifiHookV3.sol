// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IMsgSender} from "v4-periphery/src/interfaces/IMsgSender.sol";
import {ILexifiPolicy} from "./interfaces/ILexifiPolicy.sol";
import {LexifiEvents} from "./libraries/LexifiEvents.sol";

/// @title LexifiHookV3
/// @notice LexifiHook with pool admin bound to the pool's creator.
/// @dev **What changed from LexifiHook.** In LexifiHook, `setPoolPolicy` made the first caller
///      the pool's admin. A pool id is a hash of its PoolKey, so it can be computed before the
///      pool exists, and nothing tied the first caller to whoever created the pool: anyone
///      could claim a pool an issuer had announced, before or after it was initialized.
///
///      Here a pool can only be created through `createPool`, which initializes it on the
///      PoolManager and records the caller as admin in the same call. `beforeInitialize`
///      rejects any other initializer, so no pool on this hook ever exists without an admin,
///      and there is nothing left to claim. `setPoolPolicy` only lets the existing admin
///      change the policy.
///
///      Consequence: every pool on this hook is a compliance pool. There are no pass-through
///      pools, which LexifiHook allowed when no policy had been set.
///
///      Getters used by LexifiComplianceAdapter and LexifiPolicyConfigV2 (`poolPolicy`,
///      `poolAdmin`, `isCompliancePool`) keep their LexifiHook signatures.
contract LexifiHookV3 is IHooks {
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
    mapping(address => bool) public trustedRouters;

    event TrustedRouterSet(address indexed router, bool trusted);
    event PoolAdminTransferred(PoolId indexed poolId, address indexed from, address indexed to);

    error ComplianceDenied(address user, uint8 required, uint8 actual, string reason);
    error PolicyNotApproved(address policy);
    error InvalidPolicy(address policy);
    error NotPoolAdmin(address caller, PoolId poolId);
    error OnlyOwner();
    error OnlyPoolManager();
    error WrongHook(address hooks);
    error InitializeViaCreatePool(address initializer);
    error ZeroAddress();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager, address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
        owner = _owner;
    }

    // === POOL CREATION ===

    /// @notice Create a pool on this hook with a compliance policy; the caller becomes admin.
    /// @dev The only way to initialize a pool on this hook. Initialization happens first, so a
    ///      key that already exists reverts in the PoolManager before any state is written here.
    function createPool(PoolKey calldata key, uint160 sqrtPriceX96, address policy)
        external
        returns (int24 tick)
    {
        if (address(key.hooks) != address(this)) revert WrongHook(address(key.hooks));
        _validatePolicy(policy);

        tick = poolManager.initialize(key, sqrtPriceX96);

        PoolId poolId = key.toId();
        poolPolicy[poolId] = policy;
        poolAdmin[poolId] = msg.sender;
        isCompliancePool[poolId] = true;
        totalPools++;
        emit LexifiEvents.PoolPolicySet(
            poolId,
            policy,
            ILexifiPolicy(policy).policyName(),
            ILexifiPolicy(policy).policyVersion(),
            msg.sender
        );
    }

    /// @notice Change the policy of an existing pool. Pool admin only.
    function setPoolPolicy(PoolKey calldata key, address policy) external {
        PoolId poolId = key.toId();
        if (poolAdmin[poolId] != msg.sender || msg.sender == address(0)) {
            revert NotPoolAdmin(msg.sender, poolId);
        }
        _validatePolicy(policy);
        address oldPolicy = poolPolicy[poolId];
        poolPolicy[poolId] = policy;
        emit LexifiEvents.PoolPolicyUpdated(poolId, oldPolicy, policy, msg.sender);
    }

    function _validatePolicy(address policy) internal view {
        if (policy == address(0)) revert InvalidPolicy(policy);
        if (requireApproval && !approvedPolicies[policy]) revert PolicyNotApproved(policy);
        try ILexifiPolicy(policy).policyName() returns (string memory) {}
        catch {
            revert InvalidPolicy(policy);
        }
    }

    // === IHooks: beforeInitialize ===
    /// @dev `sender` is whoever called PoolManager.initialize. Only this contract may, from
    ///      `createPool`, so every pool has an admin from the block it exists.
    function beforeInitialize(address sender, PoolKey calldata, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != address(this)) revert InitializeViaCreatePool(sender);
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

    // === COMPLIANCE ENGINE (unchanged from LexifiHook) ===

    /// @notice Resolve the end user behind a PoolManager call.
    /// @dev Trusted routers expose the real user via IMsgSender.msgSender(); any other caller is
    ///      checked as itself. Never reads tx.origin.
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
        if (poolAdmin[poolId] != msg.sender || msg.sender == address(0)) {
            revert NotPoolAdmin(msg.sender, poolId);
        }
        if (newAdmin == address(0)) revert ZeroAddress();
        poolAdmin[poolId] = newAdmin;
        emit PoolAdminTransferred(poolId, msg.sender, newAdmin);
    }

    function approvePolicy(address policy) external { if (msg.sender != owner) revert OnlyOwner(); approvedPolicies[policy] = true; }
    function revokePolicy(address policy) external { if (msg.sender != owner) revert OnlyOwner(); approvedPolicies[policy] = false; }
    function setRequireApproval(bool _require) external { if (msg.sender != owner) revert OnlyOwner(); requireApproval = _require; }
    function transferOwnership(address newOwner) external { if (msg.sender != owner) revert OnlyOwner(); if (newOwner == address(0)) revert ZeroAddress(); owner = newOwner; }

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
