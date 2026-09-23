// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {SelfAttestationProvider} from "../src/policies/SelfAttestationProvider.sol";
import {LexifiPolicyConfig} from "../src/LexifiPolicyConfig.sol";
import {RegionalPolicyV3} from "../src/policies/RegionalPolicyV3.sol";
import {InstitutionalPolicyV3} from "../src/policies/InstitutionalPolicyV3.sol";
import {ThresholdPolicy} from "../src/policies/ThresholdPolicy.sol";

/// @notice One-shot policy-stack deploy for chains WITHOUT Coinbase Verifications.
///         Verified on Robinhood Chain (4663), where the EAS predeploy, the Coinbase
///         indexer and the Coinbase attester all have no code, so CoinbaseEASProvider
///         would deny every address. SelfAttestationProvider is the identity source
///         instead: the operator records its own KYC results on-chain.
///
///         Deploy LexifiHook separately with MineSalt + DeployHook (the hook address
///         has to carry the permission bits, which needs CREATE2).
///
/// Usage:
///   PRIVATE_KEY=<throwaway deployer> OWNER=<Safe or owner EOA> \
///   forge script script/DeployRobinhood.s.sol --rpc-url $RH_RPC --broadcast
contract DeployRobinhood is Script {
    function run() external {
        // Key optional: leave PRIVATE_KEY unset and pass --account <keystore> --sender <addr>.
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = deployerKey != 0 ? vm.addr(deployerKey) : msg.sender;
        address owner = vm.envAddress("OWNER");
        require(owner != deployer, "OWNER must differ from the throwaway deployer");

        console.log("=== LEXIFI POLICY STACK (self-attested identity) ===");
        console.log("Chain id:", block.chainid);
        console.log("Deployer (throwaway):", deployer);
        console.log("Owner:", owner);
        console.log("");

        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast();
        }

        // 1. Identity source. No external dependencies, so it works on any chain.
        SelfAttestationProvider provider =
            new SelfAttestationProvider(owner, "Lexifi Operator KYC");
        console.log("SelfAttestationProvider:", address(provider));

        // 2. Config registry. Ownerless by design: first writer per pool owns that pool.
        LexifiPolicyConfig registry = new LexifiPolicyConfig();
        console.log("LexifiPolicyConfig:     ", address(registry));

        // 3. Policies, all reading identity from the provider above.
        RegionalPolicyV3 regional =
            new RegionalPolicyV3(address(provider), address(registry), owner);
        console.log("RegionalPolicyV3:       ", address(regional));

        InstitutionalPolicyV3 institutional =
            new InstitutionalPolicyV3(address(registry), owner);
        console.log("InstitutionalPolicyV3:  ", address(institutional));

        ThresholdPolicy threshold = new ThresholdPolicy(address(provider), owner);
        console.log("ThresholdPolicy:        ", address(threshold));

        vm.stopBroadcast();

        console.log("");
        console.log("=== NEXT ===");
        console.log("1. MineSalt with POOL_MANAGER + OWNER set for this chain, then DeployHook.");
        console.log("2. From OWNER, attest a test wallet on SelfAttestationProvider.");
        console.log("3. Create a pool with the hook and set its policy.");
    }
}
