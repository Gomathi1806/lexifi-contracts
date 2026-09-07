// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    BaseAllowlistChecker
} from "v4-periphery/src/hooks/permissionedPools/BaseAllowListChecker.sol";
import {
    PermissionFlag,
    PermissionFlags
} from "v4-periphery/src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {ILexifiCompliance} from "./ILexifiCompliance.sol";

/// @title LexifiAllowlistChecker
/// @notice Lets a Uniswap v4 Permissioned Pool source its allowlist from Lexifi's policy engine.
/// @dev Uniswap's PermissionsAdapter delegates every permission decision to an
///      `IAllowlistChecker` that the issuer implements and deploys. This contract is that
///      implementation: instead of the issuer maintaining a hand-curated address list, the
///      answer is computed from the Lexifi policy registered for the pool — which in turn reads
///      live verification data (Coinbase EAS attestations, SelfAttestationProvider records).
///
///      Architecture:
///      ┌──────────────────────────────┐
///      │  PermissionsAdapter (Uniswap)│
///      │  _hasPermission(acct, flag)  │
///      │    checkAllowlist(acct, tkn) │ ← STATICCALL
///      └───────────────┬──────────────┘
///      ┌───────────────▼──────────────┐
///      │  LexifiAllowlistChecker      │  (this contract)
///      │  bindings[token] → poolId    │
///      │  2 × checkCompliance(...)    │
///      └───────────────┬──────────────┘
///      ┌───────────────▼──────────────┐
///      │  LexifiComplianceAdapter     │
///      │      → LexifiHook registry   │
///      │      → Threshold / Regional /│
///      │        Institutional policy  │
///      └──────────────────────────────┘
///
///      Impedance mismatch (read before deploying):
///      Uniswap's interface is `checkAllowlist(account, tokenAddress)`. It carries no pool id,
///      no operation, and no trade size — the adapter asks a pure "what may this address do
///      with this asset" question. Lexifi policies are keyed by `PoolId` and may branch on
///      `amount` (see ThresholdPolicy). Two adaptations bridge the gap:
///
///        1. token → poolId. `bindings` maps each permissioned token to the Lexifi pool whose
///           policy governs it. Uniswap passes `tokenAddress` precisely so one checker can
///           serve many assets, so this mapping is the intended extension point.
///        2. amount → `evaluationAmount`. Trade size is unknowable here, so each binding fixes
///           the notional the policy is evaluated at. Set it to the STRICTEST amount you want
///           enforced (typically above the policy's `enhancedLimit`); the address is then
///           allowlisted only if it clears the highest tier that pool can demand. Passing 0
///           would make ThresholdPolicy return INSTITUTIONAL for every address — an open pool —
///           so 0 is rejected at bind time.
///
///      Per-trade, size-dependent gating cannot be expressed through this interface at all. Pools
///      that need it should keep using LexifiHook directly, where `beforeSwap` sees the real
///      amount. Permissioned Pools and LexifiHook are complementary, not interchangeable.
///
///      Audit trail: `checkAllowlist` is `view`, so no denial events can be emitted on this path
///      (LexifiHook's `ComplianceCheckFailed` / `AuditRecord` have no counterpart here). Denials
///      surface only as a revert inside the adapter. Use `previewPermissions` off-chain to
///      recover the human-readable reason for support and reporting.
///
///      Failure mode is closed: an unbound token, a paused checker, or a reverting policy all
///      return `NONE`, which the adapter reads as "this address may do nothing".
contract LexifiAllowlistChecker is BaseAllowlistChecker {
    /// @notice Operation selectors understood by ILexifiCompliance
    uint8 internal constant OP_SWAP = 0;
    uint8 internal constant OP_ADD_LIQUIDITY = 1;

    /// @notice Lexifi compliance entry point (LexifiComplianceAdapter)
    ILexifiCompliance public immutable compliance;

    /// @param poolId The Lexifi pool whose policy governs this token
    /// @param evaluationAmount Notional the policy is evaluated at, in token0 terms
    /// @param liquidityRequiresSwap Withhold LIQUIDITY_ALLOWED from addresses denied SWAP_ALLOWED
    /// @param active False for tokens that were never bound or have been unbound
    struct TokenBinding {
        bytes32 poolId;
        uint256 evaluationAmount;
        bool liquidityRequiresSwap;
        bool active;
    }

    /// @notice Permissioned token → the Lexifi pool policy that governs it
    mapping(address => TokenBinding) public bindings;

    address public owner;

    /// @notice Issuer-level kill switch. While true every address is denied every permission.
    bool public paused;

    event TokenBound(
        address indexed token,
        bytes32 indexed poolId,
        uint256 evaluationAmount,
        bool liquidityRequiresSwap
    );
    event TokenUnbound(address indexed token);
    event EvaluationAmountUpdated(address indexed token, uint256 oldAmount, uint256 newAmount);
    event PausedSet(bool paused);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error OnlyOwner();
    error ZeroAddress();
    error TokenNotBound(address token);
    error ZeroEvaluationAmount();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor(ILexifiCompliance _compliance, address _owner) {
        if (address(_compliance) == address(0) || _owner == address(0)) revert ZeroAddress();
        compliance = _compliance;
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);
    }

    // ═══════════════════════════════════════════
    //  IAllowlistChecker
    // ═══════════════════════════════════════════

    /// @inheritdoc BaseAllowlistChecker
    /// @dev Called by PermissionsAdapter as
    ///      `(checkAllowlist(account, token) & permission) == permission`, so returning a
    ///      superset of the requested bits is safe and returning NONE denies everything.
    function checkAllowlist(address account, address tokenAddress)
        public
        view
        override
        returns (PermissionFlag)
    {
        if (paused) return PermissionFlags.NONE;

        TokenBinding memory binding = bindings[tokenAddress];
        if (!binding.active) return PermissionFlags.NONE;

        PermissionFlag flags = PermissionFlags.NONE;

        bool swapAllowed = _allowed(binding, account, OP_SWAP);
        if (swapAllowed) {
            flags = flags | PermissionFlags.SWAP_ALLOWED;
        }

        // An LP position in a permissioned pool is exposure to the permissioned token, so an
        // address barred from buying the asset generally must not be able to acquire it by
        // providing liquidity instead. Lexifi policies can legitimately answer the two
        // questions differently — ThresholdPolicy gates swaps on trade size but gates LPs on
        // tier alone, so a RETAIL address denied a large swap still clears the LP check — and
        // that asymmetry is a hole once it reaches an allowlist. Closed by default; issuers who
        // genuinely want LP-only participants can opt out per token.
        if (
            (swapAllowed || !binding.liquidityRequiresSwap)
                && _allowed(binding, account, OP_ADD_LIQUIDITY)
        ) {
            flags = flags | PermissionFlags.LIQUIDITY_ALLOWED;
        }

        return flags;
    }

    /// @dev A policy that reverts (misconfigured, provider outage, self-destructed) denies rather
    ///      than throws: a revert here would bubble up and brick the whole pool, including exits.
    function _allowed(TokenBinding memory binding, address account, uint8 operation)
        internal
        view
        returns (bool)
    {
        try compliance.checkCompliance(
            binding.poolId, account, operation, binding.evaluationAmount
        ) returns (
            bool allowed, uint8, uint8, string memory
        ) {
            return allowed;
        } catch {
            return false;
        }
    }

    // ═══════════════════════════════════════════
    //  VIEWS
    // ═══════════════════════════════════════════

    /// @notice Full compliance answer for a token, including the reason a flag was withheld.
    /// @dev Off-chain companion to `checkAllowlist`, which can only return opaque bits. Use this
    ///      to tell a rejected user *why* — the dashboard's "why was I denied" surface.
    function previewPermissions(address account, address tokenAddress)
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
        TokenBinding memory binding = bindings[tokenAddress];
        if (!binding.active || paused) {
            return (false, false, 0, 0, paused ? "Checker paused" : "Token not bound");
        }

        (swapAllowed, userTier, requiredSwapTier, reason) =
            compliance.checkCompliance(binding.poolId, account, OP_SWAP, binding.evaluationAmount);
        (liquidityAllowed,,,) = compliance.checkCompliance(
            binding.poolId, account, OP_ADD_LIQUIDITY, binding.evaluationAmount
        );

        // Mirror the coupling applied in checkAllowlist so preview never disagrees with the
        // flags the adapter actually sees.
        if (binding.liquidityRequiresSwap && !swapAllowed) {
            liquidityAllowed = false;
        }
    }

    /// @notice Whether a token is bound and the Lexifi pool behind it has a policy registered.
    function isTokenGoverned(address tokenAddress) external view returns (bool) {
        TokenBinding memory binding = bindings[tokenAddress];
        if (!binding.active) return false;
        return compliance.hasPolicy(binding.poolId);
    }

    // ═══════════════════════════════════════════
    //  ADMIN
    // ═══════════════════════════════════════════

    /// @notice Point a permissioned token at the Lexifi pool policy that governs it.
    /// @dev Re-binding an already-bound token overwrites its configuration in place.
    /// @param evaluationAmount The notional policies are evaluated at. Set this to the strictest
    ///        tier boundary you want enforced; `type(uint256).max` gates on the highest tier the
    ///        pool's policy can demand.
    /// @param liquidityRequiresSwap Pass true (recommended) so an address denied SWAP_ALLOWED
    ///        cannot acquire the asset by providing liquidity instead. Pass false only for pools
    ///        that deliberately admit LP-only participants.
    function bindToken(
        address token,
        bytes32 poolId,
        uint256 evaluationAmount,
        bool liquidityRequiresSwap
    ) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (evaluationAmount == 0) revert ZeroEvaluationAmount();

        bindings[token] = TokenBinding({
            poolId: poolId,
            evaluationAmount: evaluationAmount,
            liquidityRequiresSwap: liquidityRequiresSwap,
            active: true
        });
        emit TokenBound(token, poolId, evaluationAmount, liquidityRequiresSwap);
    }

    /// @notice Stop governing a token. Every address is denied every permission for it afterwards.
    function unbindToken(address token) external onlyOwner {
        if (!bindings[token].active) revert TokenNotBound(token);
        delete bindings[token];
        emit TokenUnbound(token);
    }

    /// @notice Re-tune the notional an already-bound token is evaluated at.
    function setEvaluationAmount(address token, uint256 newAmount) external onlyOwner {
        TokenBinding storage binding = bindings[token];
        if (!binding.active) revert TokenNotBound(token);
        if (newAmount == 0) revert ZeroEvaluationAmount();

        uint256 oldAmount = binding.evaluationAmount;
        binding.evaluationAmount = newAmount;
        emit EvaluationAmountUpdated(token, oldAmount, newAmount);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }
}
