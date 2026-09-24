// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    BaseAllowlistChecker
} from "v4-periphery/src/hooks/permissionedPools/BaseAllowListChecker.sol";
import {
    PermissionFlag,
    PermissionFlags
} from "v4-periphery/src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {
    IPermissionsAdapter
} from "v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {ILexifiCompliance} from "./ILexifiCompliance.sol";

/// @title LexifiAllowlistCheckerV2
/// @notice Self-serve Lexifi allowlist for Uniswap v4 Permissioned Pools. No owner.
/// @dev **What changed from LexifiAllowlistChecker.** V1 bound tokens globally
///      (`bindings[token]`) and only its owner, the Lexifi Safe, could bind, so every issuer
///      needed Lexifi to act for them. V2 binds per PermissionsAdapter, and the adapter's own
///      owner (the issuer) does the binding:
///
///        - `bindings[adapter]`. Only a PermissionsAdapter calls `checkAllowlist`
///          (PermissionsAdapter.isAllowed), so `msg.sender` identifies the adapter and its
///          binding. Two issuers wrapping the same token get separate bindings and cannot
///          overwrite each other.
///        - `bind(adapter, ...)` requires `msg.sender == adapter.owner()`. That owner already
///          chooses which allowlist checker the adapter uses (`updateAllowListChecker`), so
///          letting it also pick the Lexifi pool gives it no new power.
///        - The token is read from `adapter.PERMISSIONED_TOKEN()` at bind time, and
///          `checkAllowlist` returns NONE if the token it is asked about differs.
///        - The global owner and global pause are gone. Each binding has its own pause, set by
///          that adapter's owner.
///
///      Pool choice: the issuer may bind to any Lexifi pool with a policy, including one it
///      does not administer. That pool's admin can then change the policy, so issuers should
///      bind to a pool they control. Binding reads that pool's policy; it cannot change it.
///
///      Everything else is as in V1: `evaluationAmount` stands in for the trade size the
///      interface cannot carry (0 is rejected), `liquidityRequiresSwap` closes the LP
///      back door, and a reverting policy, an unbound adapter or a paused binding all return
///      NONE (fail-closed).
contract LexifiAllowlistCheckerV2 is BaseAllowlistChecker {
    uint8 internal constant OP_SWAP = 0;
    uint8 internal constant OP_ADD_LIQUIDITY = 1;

    /// @notice Lexifi compliance entry point (LexifiComplianceAdapter)
    ILexifiCompliance public immutable compliance;

    struct Binding {
        address token;
        bytes32 poolId;
        uint256 evaluationAmount;
        bool liquidityRequiresSwap;
        bool active;
        bool paused;
    }

    /// @notice PermissionsAdapter → the Lexifi pool policy that governs its token
    mapping(address => Binding) public bindings;

    event Bound(
        address indexed adapter,
        address indexed token,
        bytes32 indexed poolId,
        uint256 evaluationAmount,
        bool liquidityRequiresSwap,
        address by
    );
    event Unbound(address indexed adapter, address by);
    event EvaluationAmountUpdated(address indexed adapter, uint256 oldAmount, uint256 newAmount);
    event PausedSet(address indexed adapter, bool paused);

    error ZeroAddress();
    error NotAdapterOwner(address caller, address adapter);
    error NotBound(address adapter);
    error ZeroEvaluationAmount();
    error NoPolicyForPool(bytes32 poolId);

    modifier onlyAdapterOwner(address adapter) {
        if (adapter == address(0)) revert ZeroAddress();
        if (IPermissionsAdapter(adapter).owner() != msg.sender) {
            revert NotAdapterOwner(msg.sender, adapter);
        }
        _;
    }

    constructor(ILexifiCompliance _compliance) {
        if (address(_compliance) == address(0)) revert ZeroAddress();
        compliance = _compliance;
    }

    // ═══════════════════════════════════════════
    //  IAllowlistChecker
    // ═══════════════════════════════════════════

    /// @inheritdoc BaseAllowlistChecker
    /// @dev `msg.sender` is the PermissionsAdapter asking. Any other caller has no binding and
    ///      gets NONE; use `previewPermissions` off-chain.
    function checkAllowlist(address account, address tokenAddress)
        public
        view
        override
        returns (PermissionFlag)
    {
        return _flags(bindings[msg.sender], account, tokenAddress);
    }

    function _flags(Binding memory binding, address account, address tokenAddress)
        internal
        view
        returns (PermissionFlag flags)
    {
        if (!binding.active || binding.paused || binding.token != tokenAddress) {
            return PermissionFlags.NONE;
        }

        bool swapAllowed = _allowed(binding, account, OP_SWAP);
        if (swapAllowed) flags = flags | PermissionFlags.SWAP_ALLOWED;

        if (
            (swapAllowed || !binding.liquidityRequiresSwap)
                && _allowed(binding, account, OP_ADD_LIQUIDITY)
        ) {
            flags = flags | PermissionFlags.LIQUIDITY_ALLOWED;
        }
    }

    /// @dev A reverting policy denies rather than throws, so it cannot brick the pool.
    function _allowed(Binding memory binding, address account, uint8 operation)
        internal
        view
        returns (bool)
    {
        try compliance.checkCompliance(
            binding.poolId, account, operation, binding.evaluationAmount
        ) returns (bool allowed, uint8, uint8, string memory) {
            return allowed;
        } catch {
            return false;
        }
    }

    // ═══════════════════════════════════════════
    //  VIEWS
    // ═══════════════════════════════════════════

    /// @notice The flags `adapter` would get for `account`, as seen by the adapter.
    function flagsFor(address adapter, address account) external view returns (PermissionFlag) {
        Binding memory binding = bindings[adapter];
        return _flags(binding, account, binding.token);
    }

    /// @notice Full compliance answer for an adapter, including the reason a flag was withheld.
    function previewPermissions(address adapter, address account)
        external
        view
        returns (
            bool swapAllowed,
            bool liquidityAllowed,
            uint8 userTier,
            uint8 requiredSwapTier,
            string memory reason
        )
    {
        Binding memory binding = bindings[adapter];
        if (!binding.active || binding.paused) {
            return (false, false, 0, 0, binding.paused ? "Binding paused" : "Adapter not bound");
        }

        (swapAllowed, userTier, requiredSwapTier, reason) =
            compliance.checkCompliance(binding.poolId, account, OP_SWAP, binding.evaluationAmount);
        (liquidityAllowed,,,) = compliance.checkCompliance(
            binding.poolId, account, OP_ADD_LIQUIDITY, binding.evaluationAmount
        );
        if (binding.liquidityRequiresSwap && !swapAllowed) liquidityAllowed = false;
    }

    /// @notice Whether an adapter is bound, unpaused, and its Lexifi pool has a policy.
    function isGoverned(address adapter) external view returns (bool) {
        Binding memory binding = bindings[adapter];
        if (!binding.active || binding.paused) return false;
        return compliance.hasPolicy(binding.poolId);
    }

    // ═══════════════════════════════════════════
    //  ISSUER ADMIN (the adapter's owner)
    // ═══════════════════════════════════════════

    /// @notice Point a PermissionsAdapter at the Lexifi pool policy that governs its token.
    /// @dev Re-binding overwrites in place and clears a pause.
    /// @param evaluationAmount Notional the policy is evaluated at; see the contract notes.
    /// @param liquidityRequiresSwap True (recommended) to withhold LIQUIDITY_ALLOWED from
    ///        addresses denied SWAP_ALLOWED.
    function bind(
        address adapter,
        bytes32 poolId,
        uint256 evaluationAmount,
        bool liquidityRequiresSwap
    ) external onlyAdapterOwner(adapter) {
        if (evaluationAmount == 0) revert ZeroEvaluationAmount();
        if (!compliance.hasPolicy(poolId)) revert NoPolicyForPool(poolId);
        address token = address(IPermissionsAdapter(adapter).PERMISSIONED_TOKEN());
        if (token == address(0)) revert ZeroAddress();

        bindings[adapter] = Binding({
            token: token,
            poolId: poolId,
            evaluationAmount: evaluationAmount,
            liquidityRequiresSwap: liquidityRequiresSwap,
            active: true,
            paused: false
        });
        emit Bound(adapter, token, poolId, evaluationAmount, liquidityRequiresSwap, msg.sender);
    }

    /// @notice Stop governing an adapter. Every address is denied afterwards.
    function unbind(address adapter) external onlyAdapterOwner(adapter) {
        if (!bindings[adapter].active) revert NotBound(adapter);
        delete bindings[adapter];
        emit Unbound(adapter, msg.sender);
    }

    /// @notice Re-tune the notional a bound adapter is evaluated at.
    function setEvaluationAmount(address adapter, uint256 newAmount)
        external
        onlyAdapterOwner(adapter)
    {
        Binding storage binding = bindings[adapter];
        if (!binding.active) revert NotBound(adapter);
        if (newAmount == 0) revert ZeroEvaluationAmount();
        uint256 oldAmount = binding.evaluationAmount;
        binding.evaluationAmount = newAmount;
        emit EvaluationAmountUpdated(adapter, oldAmount, newAmount);
    }

    /// @notice Issuer kill switch for one adapter. While paused every address is denied.
    function setPaused(address adapter, bool paused) external onlyAdapterOwner(adapter) {
        if (!bindings[adapter].active) revert NotBound(adapter);
        bindings[adapter].paused = paused;
        emit PausedSet(adapter, paused);
    }
}
