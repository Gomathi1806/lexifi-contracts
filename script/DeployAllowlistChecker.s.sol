// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {LexifiComplianceAdapter} from "../src/integrations/LexifiComplianceAdapter.sol";
import {LexifiAllowlistChecker} from "../src/integrations/LexifiAllowlistChecker.sol";
import {ILexifiCompliance} from "../src/integrations/ILexifiCompliance.sol";

/// @notice Deploys the Uniswap v4 Permissioned Pools integration:
///         LexifiComplianceAdapter (if not already live) + LexifiAllowlistChecker.
///
/// @dev OWNER (Safe) controls the checker — NOT the deployer key. Because the Safe owns it,
///      this script cannot call `bindToken`; it prints the calldata for you to execute from
///      app.safe.global instead. A checker with no bindings denies every address, which is the
///      correct state to deploy in: nothing is live until the Safe deliberately binds a token.
///
///      Required env:
///        PRIVATE_KEY     throwaway deployer
///        OWNER           Safe multisig
///        LEXIFI_HOOK     deployed LexifiHook (holds the pool → policy registry)
///
///      Optional env:
///        COMPLIANCE_ADAPTER   reuse an existing LexifiComplianceAdapter instead of deploying
///        PERMISSIONED_TOKEN   token to print bindToken calldata for
///        POOL_ID              bytes32 PoolId whose Lexifi policy governs that token
///        EVALUATION_AMOUNT    notional policies are evaluated at (default: type(uint256).max)
///        LIQUIDITY_REQUIRES_SWAP  withhold LP rights from addresses denied swap (default: true)
contract DeployAllowlistChecker is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address owner = vm.envAddress("OWNER");
        address lexifiHook = vm.envAddress("LEXIFI_HOOK");

        require(owner != deployer, "OWNER must differ from throwaway deployer");
        require(lexifiHook.code.length > 0, "LEXIFI_HOOK has no code on this chain");

        console.log("Deployer (throwaway):", deployer);
        console.log("Owner (Safe):", owner);
        console.log("LexifiHook:", lexifiHook);
        console.log("Chain ID:", block.chainid);

        // Coinbase Verifications attestations are issued on Base only. On any other chain the
        // CoinbaseEASProvider resolves every address to tier 0, and because this stack fails
        // closed that produces a pool which denies everyone. Use SelfAttestationProvider (or a
        // chain-native provider) there instead.
        if (block.chainid != 8453 && block.chainid != 84532) {
            console.log("");
            console.log("!! NOT BASE - Coinbase EAS attestations do not exist on this chain.");
            console.log("!! Policies backed by CoinbaseEASProvider will deny every address.");
        }

        vm.startBroadcast(deployerKey);

        address adapter = vm.envOr("COMPLIANCE_ADAPTER", address(0));
        if (adapter == address(0)) {
            adapter = address(new LexifiComplianceAdapter(lexifiHook));
            console.log("LexifiComplianceAdapter (new):", adapter);
        } else {
            require(adapter.code.length > 0, "COMPLIANCE_ADAPTER has no code on this chain");
            require(
                LexifiComplianceAdapter(adapter).lexifiHook() == lexifiHook,
                "COMPLIANCE_ADAPTER points at a different hook"
            );
            console.log("LexifiComplianceAdapter (reused):", adapter);
        }

        LexifiAllowlistChecker checker =
            new LexifiAllowlistChecker(ILexifiCompliance(adapter), owner);
        console.log("LexifiAllowlistChecker:", address(checker));

        vm.stopBroadcast();

        _report(address(checker), adapter, owner);
    }

    function _report(address checker, address adapter, address owner) internal view {
        console.log("");
        console.log("=== PERMISSIONED POOLS INTEGRATION DEPLOYED ===");
        console.log("LexifiComplianceAdapter:", adapter);
        console.log("LexifiAllowlistChecker: ", checker);
        console.log("Owner (Safe):           ", owner);
        console.log("");
        console.log("The checker currently denies EVERY address: no tokens are bound yet.");
        console.log("");
        console.log("Next steps:");
        console.log(" 1. Safe tx -> checker.bindToken(token, poolId, evaluationAmount, true)");
        console.log(
            " 2. Issuer deploys a PermissionsAdapter via Uniswap's PermissionsAdapterFactory,"
        );
        console.log("    passing this checker as the allowlist checker.");
        console.log(
            " 3. Verify with checker.previewPermissions(user, token) before opening the pool."
        );
        console.log(" 4. Add the checker address to lexifi-sdk/src/addresses.ts.");

        _printBindCalldata(checker);
    }

    /// @dev bindToken is onlyOwner and the owner is the Safe, so the deployer cannot call it.
    ///      Print the calldata to paste into a Safe transaction instead.
    function _printBindCalldata(address checker) internal view {
        address token = vm.envOr("PERMISSIONED_TOKEN", address(0));
        if (token == address(0)) {
            console.log("");
            console.log(
                "Set PERMISSIONED_TOKEN + POOL_ID to also print the Safe bindToken calldata."
            );
            return;
        }

        bytes32 poolId = vm.envBytes32("POOL_ID");
        uint256 evaluationAmount = vm.envOr("EVALUATION_AMOUNT", type(uint256).max);
        bool liquidityRequiresSwap = vm.envOr("LIQUIDITY_REQUIRES_SWAP", true);

        require(evaluationAmount != 0, "EVALUATION_AMOUNT of 0 would open the pool to everyone");

        console.log("");
        console.log("=== SAFE TRANSACTION: bindToken ===");
        console.log("To:   ", checker);
        console.log("Value: 0");
        console.log("Token:", token);
        console.log("Evaluation amount:", evaluationAmount);
        console.log("Liquidity requires swap:", liquidityRequiresSwap);
        console.log("Data:");
        console.logBytes(
            abi.encodeCall(
                LexifiAllowlistChecker.bindToken,
                (token, poolId, evaluationAmount, liquidityRequiresSwap)
            )
        );
    }
}
