// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILexifiCompliance} from "../../src/integrations/ILexifiCompliance.sol";

/// @title MockAqua0V4Adapter
/// @notice Demonstrates how Aqua0's V4Adapter would integrate Lexifi compliance.
/// @dev This mock simulates Aqua0's beforeSwap flow:
///      1. Validate EIP-712 JIT authorization (simulated)
///      2. Check Lexifi compliance (the new addition)
///      3. Inject JIT liquidity range (simulated)
///
///      In Aqua0's real V4Adapter, step 2 is a single line addition.
///      The compliance check is a STATICCALL — no state changes, no gas
///      overhead beyond the policy lookup, and it reverts the swap if denied.
contract MockAqua0V4Adapter {
    ILexifiCompliance public complianceAdapter;
    bool public complianceEnabled;

    event JITInjected(bytes32 poolId, address trader, uint256 amount);
    event ComplianceCheckResult(bytes32 poolId, address trader, bool allowed, uint8 userTier, uint8 requiredTier);

    error ComplianceDenied(address user, string reason);
    error InvalidJITAuth();

    constructor(address _complianceAdapter) {
        if (_complianceAdapter != address(0)) {
            complianceAdapter = ILexifiCompliance(_complianceAdapter);
            complianceEnabled = true;
        }
    }

    /// @notice Enable/disable compliance checking
    function setComplianceAdapter(address _adapter) external {
        if (_adapter == address(0)) {
            complianceEnabled = false;
        } else {
            complianceAdapter = ILexifiCompliance(_adapter);
            complianceEnabled = true;
        }
    }

    /// @notice Simulates Aqua0's V4Adapter.beforeSwap flow
    /// @dev In the real adapter, this is called by the PoolManager during a swap.
    ///      The hookData contains the EIP-712 JIT authorization signed by Aqua0's backend.
    function simulateBeforeSwap(
        bytes32 poolId,
        address trader,
        uint256 amount,
        bytes calldata jitAuth
    ) external returns (bool) {
        // Step 1: Validate EIP-712 JIT authorization (Aqua0's existing logic)
        _validateJITAuth(jitAuth);

        // Step 2: Lexifi compliance check — THE ONE NEW LINE
        if (complianceEnabled && address(complianceAdapter) != address(0)) {
            _enforceCompliance(poolId, trader, 0, amount);
        }

        // Step 3: Inject JIT liquidity (Aqua0's existing logic)
        _injectJITLiquidity(poolId, trader, amount);

        return true;
    }

    /// @notice Simulates Aqua0's vault LP deposit with compliance gating
    function simulateVaultDeposit(
        bytes32 poolId,
        address lp,
        uint256 amount
    ) external returns (bool) {
        // Compliance check for LP deposits (operation=1 for addLiquidity)
        if (complianceEnabled && address(complianceAdapter) != address(0)) {
            _enforceCompliance(poolId, lp, 1, amount);
        }

        return true;
    }

    function _enforceCompliance(
        bytes32 poolId,
        address user,
        uint8 operation,
        uint256 amount
    ) internal view {
        (bool allowed, uint8 userTier, uint8 requiredTier, string memory reason) =
            complianceAdapter.checkCompliance(poolId, user, operation, amount);

        if (!allowed) {
            revert ComplianceDenied(user, reason);
        }
    }

    function _validateJITAuth(bytes calldata jitAuth) internal pure {
        // Simulated: in Aqua0's real code, this validates the EIP-712 signature
        // from their backend authorizing the JIT liquidity injection
        if (jitAuth.length == 0) revert InvalidJITAuth();
    }

    function _injectJITLiquidity(bytes32 poolId, address trader, uint256 amount) internal {
        // Simulated: in Aqua0's real code, this adds a temporary concentrated
        // liquidity position around the swap price, sourced from the vault
        emit JITInjected(poolId, trader, amount);
    }
}
