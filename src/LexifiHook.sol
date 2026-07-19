// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ILexifiPolicy} from "./interfaces/ILexifiPolicy.sol";
import {LexifiEvents} from "./libraries/LexifiEvents.sol";

/// @title LexifiHook
/// @notice Pool-Level Compliance Hook for Uniswap V4.
/// @dev Each pool gets its own compliance policy set by the pool creator during initialization.
///      DEXs use this hook to launch "Verified Only" pools with customizable rules.
///
///      Architecture:
///      - beforeInitialize: Pool creator registers a compliance policy for the pool
///      - beforeSwap: Enforce compliance check via the pool's policy contract
///      - beforeAddLiquidity: Enforce compliance for LP deposits
///      - beforeRemoveLiquidity: ALWAYS ALLOWED (never trap user funds)
///
///      Flash Accounting Integration:
///      - If a user becomes non-compliant mid-transaction (e.g. sanctioned during
///        a multi-hop swap), the beforeSwap check reverts, and v4's flash accounting
///        ensures NO tokens move — the entire unlock() call is atomic.
contract LexifiHook is IHooks {
    using PoolIdLibrary for PoolKey;

    // ═══════════════════════════════════════════
    //  IMMUTABLES
    // ═══════════════════════════════════════════

    IPoolManager public immutable poolManager;

    // ═══════════════════════════════════════════
    //  STATE
    // ═══════════════════════════════════════════

    /// @notice Policy contract assigned to each pool
    mapping(PoolId => address) public poolPolicy;

    /// @notice Who created/owns each pool's compliance config
    mapping(PoolId => address) public poolAdmin;

    /// @notice Whether a pool has compliance enabled
    mapping(PoolId => bool) public isCompliancePool;

    /// @notice Global registry owner (Lexifi)
    address public owner;

    /// @notice Approved policy contracts (audited by Lexifi)
    mapping(address => bool) public approvedPolicies;

    /// @notice Whether to require Lexifi-approved policies only
    bool public requireApproval;

    /// @notice Total compliance checks performed (for analytics)
    uint256 public totalChecks;

    /// @notice Total pools using Lexifi compliance
    uint256 public totalPools;

    // ═══════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════

    error ComplianceDenied(address user, uint8 required, uint8 actual, string reason);
    error PolicyNotApproved(address policy);
    error InvalidPolicy(address policy);
    error NotPoolAdmin(address caller, PoolId poolId);
    error OnlyOwner();
    error OnlyPoolManager();

    // ═══════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    // ═══════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════

    constructor(
        IPoolManager _poolManager,
        address _owner
    ) {
        poolManager = _poolManager;
        owner = _owner;
        requireApproval = false;
    }

    // ═══════════════════════════════════════════
    //  HOOK PERMISSIONS
    // ═══════════════════════════════════════════

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false, // NEVER block exits
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ═══════════════════════════════════════════
    //  IHooks CALLBACKS — ACTIVE
    // ═══════════════════════════════════════════

    /// @notice Called when a pool is created. Pool creator sets their compliance policy.
    function beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4) {
        if (hookData.length == 0) {
            return this.beforeInitialize.selector;
        }

        address policy = abi.decode(hookData, (address));

        if (policy == address(0)) revert InvalidPolicy(policy);
        if (requireApproval && !approvedPolicies[policy]) revert PolicyNotApproved(policy);

        try ILexifiPolicy(policy).policyName() returns (string memory) {} catch {
            revert InvalidPolicy(policy);
        }

        PoolId poolId = key.toId();
        poolPolicy[poolId] = policy;
        poolAdmin[poolId] = sender;
        isCompliancePool[poolId] = true;
        totalPools++;

        emit LexifiEvents.PoolPolicySet(
            poolId,
            policy,
            ILexifiPolicy(policy).policyName(),
            ILexifiPolicy(policy).policyVersion(),
            sender
        );

        return this.beforeInitialize.selector;
    }

    /// @notice Enforce compliance on every swap.
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();

        if (isCompliancePool[poolId]) {
            uint256 amount = params.amountSpecified < 0
                ? uint256(-params.amountSpecified)
                : uint256(params.amountSpecified);

            _enforceCompliance(poolId, tx.origin, 0, amount);
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Enforce compliance on adding liquidity
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external onlyPoolManager returns (bytes4) {
        PoolId poolId = key.toId();

        if (isCompliancePool[poolId]) {
            uint256 amount = params.liquidityDelta > 0
                ? uint256(params.liquidityDelta)
                : 0;

            _enforceCompliance(poolId, tx.origin, 1, amount);
        }

        return this.beforeAddLiquidity.selector;
    }

    // NOTE: beforeRemoveLiquidity is NOT hooked.
    // Users can ALWAYS exit. Never trap funds. This is a core Lexifi principle.

    // ═══════════════════════════════════════════
    //  IHooks CALLBACKS — NOT USED (required by interface)
    // ═══════════════════════════════════════════

    function afterInitialize(address, PoolKey calldata, uint160, int24, bytes calldata)
        external pure returns (bytes4) { return this.afterInitialize.selector; }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external pure returns (bytes4) { return this.beforeRemoveLiquidity.selector; }

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure returns (bytes4, BalanceDelta) { return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0)); }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure returns (bytes4, BalanceDelta) { return (this.afterRemoveLiquidity.selector, BalanceDelta.wrap(0)); }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external pure returns (bytes4, int128) { return (this.afterSwap.selector, 0); }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure returns (bytes4) { return this.beforeDonate.selector; }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure returns (bytes4) { return this.afterDonate.selector; }

    // ═══════════════════════════════════════════
    //  INTERNAL: COMPLIANCE ENGINE
    // ═══════════════════════════════════════════

    function _enforceCompliance(
        PoolId poolId,
        address user,
        uint8 operation,
        uint256 amount
    ) internal {
        address policy = poolPolicy[poolId];
        totalChecks++;

        (ILexifiPolicy.AccessLevel level, string memory reason) =
            ILexifiPolicy(policy).checkAccess(poolId, user, operation, amount);

        ILexifiPolicy.AccessLevel required =
            ILexifiPolicy(policy).minimumLevel(poolId, operation);

        if (uint8(level) < uint8(required)) {
            emit LexifiEvents.ComplianceCheckFailed(
                poolId, user, operation,
                uint8(level), uint8(required),
                reason, block.timestamp
            );

            emit LexifiEvents.AuditRecord(
                bytes32(0), poolId, user, operation, false, amount,
                block.number, block.timestamp
            );

            revert ComplianceDenied(user, uint8(required), uint8(level), reason);
        }

        emit LexifiEvents.ComplianceCheckPassed(
            poolId, user, operation,
            uint8(level), uint8(required),
            amount, block.timestamp
        );

        emit LexifiEvents.AuditRecord(
            bytes32(0), poolId, user, operation, true, amount,
            block.number, block.timestamp
        );
    }

    // ═══════════════════════════════════════════
    //  POOL ADMIN FUNCTIONS
    // ═══════════════════════════════════════════

    function updatePoolPolicy(
        PoolKey calldata key,
        address newPolicy
    ) external {
        PoolId poolId = key.toId();
        if (poolAdmin[poolId] != msg.sender) revert NotPoolAdmin(msg.sender, poolId);
        if (newPolicy == address(0)) revert InvalidPolicy(newPolicy);
        if (requireApproval && !approvedPolicies[newPolicy]) revert PolicyNotApproved(newPolicy);

        address oldPolicy = poolPolicy[poolId];
        poolPolicy[poolId] = newPolicy;

        emit LexifiEvents.PoolPolicyUpdated(poolId, oldPolicy, newPolicy, msg.sender);
    }

    function transferPoolAdmin(PoolKey calldata key, address newAdmin) external {
        PoolId poolId = key.toId();
        if (poolAdmin[poolId] != msg.sender) revert NotPoolAdmin(msg.sender, poolId);
        poolAdmin[poolId] = newAdmin;
    }

    // ═══════════════════════════════════════════
    //  LEXIFI OWNER FUNCTIONS
    // ═══════════════════════════════════════════

    function approvePolicy(address policy) external {
        if (msg.sender != owner) revert OnlyOwner();
        approvedPolicies[policy] = true;
    }

    function revokePolicy(address policy) external {
        if (msg.sender != owner) revert OnlyOwner();
        approvedPolicies[policy] = false;
    }

    function setRequireApproval(bool _require) external {
        if (msg.sender != owner) revert OnlyOwner();
        requireApproval = _require;
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert OnlyOwner();
        owner = newOwner;
    }

    // ═══════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════

    function checkUserCompliance(
        PoolKey calldata key,
        address user,
        uint8 operation,
        uint256 amount
    ) external view returns (
        bool allowed,
        uint8 userLevel,
        uint8 requiredLevel,
        string memory reason
    ) {
        PoolId poolId = key.toId();
        if (!isCompliancePool[poolId]) return (true, 3, 0, "");

        address policy = poolPolicy[poolId];
        (ILexifiPolicy.AccessLevel level, string memory _reason) =
            ILexifiPolicy(policy).checkAccess(poolId, user, operation, amount);

        ILexifiPolicy.AccessLevel required =
            ILexifiPolicy(policy).minimumLevel(poolId, operation);

        return (
            uint8(level) >= uint8(required),
            uint8(level),
            uint8(required),
            _reason
        );
    }

    function getPoolInfo(PoolKey calldata key) external view returns (
        bool hasCompliance,
        address policy,
        string memory policyName,
        address admin
    ) {
        PoolId poolId = key.toId();
        if (!isCompliancePool[poolId]) return (false, address(0), "", address(0));

        address _policy = poolPolicy[poolId];
        return (
            true,
            _policy,
            ILexifiPolicy(_policy).policyName(),
            poolAdmin[poolId]
        );
    }
}
