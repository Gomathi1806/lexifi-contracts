// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {CoinbaseEASProvider} from "../src/policies/CoinbaseEASProvider.sol";
import {ThresholdPolicy} from "../src/policies/ThresholdPolicy.sol";
import {RegionalPolicy} from "../src/policies/RegionalPolicy.sol";
import {InstitutionalPolicy} from "../src/policies/InstitutionalPolicy.sol";

/// @notice Deploys the provider + 3 policy templates.
///         OWNER (Smart Wallet / Safe) controls the policies — NOT the deployer key.
contract DeployPolicies is Script {
    // EAS predeploy + Coinbase indexer/attester (same on Base mainnet & Base Sepolia)
    address constant EAS = 0x4200000000000000000000000000000000000021;
    address constant EAS_INDEXER = 0x2c7eE1E5f416dfF40054c27A62f7B357C4E8619C;
    address constant CB_ATTESTER = 0x357458739F90461b99789350868CD7CF330Dd7EE;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address owner = vm.envAddress("OWNER"); // Smart Wallet or Safe — never the deployer EOA
        require(owner != deployer, "OWNER must differ from throwaway deployer");

        console.log("Deployer (throwaway):", deployer);
        console.log("Owner (Smart Wallet/Safe):", owner);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerKey);

        CoinbaseEASProvider provider = new CoinbaseEASProvider(EAS, EAS_INDEXER, CB_ATTESTER);
        console.log("CoinbaseEASProvider:", address(provider));

        ThresholdPolicy threshold = new ThresholdPolicy(address(provider), owner);
        console.log("ThresholdPolicy:", address(threshold));

        RegionalPolicy regional = new RegionalPolicy(address(provider), owner);
        console.log("RegionalPolicy:", address(regional));

        InstitutionalPolicy institutional = new InstitutionalPolicy(owner);
        console.log("InstitutionalPolicy:", address(institutional));

        vm.stopBroadcast();

        console.log("");
        console.log("=== POLICIES DEPLOYED (owner = Smart Wallet/Safe) ===");
        console.log("Next: MineSalt, then DeployHook.");
    }
}
