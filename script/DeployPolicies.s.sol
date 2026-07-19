// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {CoinbaseEASProvider} from "../src/policies/CoinbaseEASProvider.sol";
import {ThresholdPolicy} from "../src/policies/ThresholdPolicy.sol";
import {RegionalPolicy} from "../src/policies/RegionalPolicy.sol";
import {InstitutionalPolicy} from "../src/policies/InstitutionalPolicy.sol";

contract DeployPolicies is Script {
    // Base Sepolia addresses
    address constant EAS = 0x4200000000000000000000000000000000000021;
    address constant EAS_INDEXER = 0x2c7eE1E5f416dfF40054c27A62f7B357C4E8619C;
    address constant CB_ATTESTER = 0x357458739F90461b99789350868CD7CF330Dd7EE;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast(deployerKey);

        // 1. Deploy CoinbaseEASProvider
        CoinbaseEASProvider provider = new CoinbaseEASProvider(
            EAS,
            EAS_INDEXER,
            CB_ATTESTER
        );
        console.log("CoinbaseEASProvider:", address(provider));

        // 2. Deploy ThresholdPolicy (retail pools)
        ThresholdPolicy threshold = new ThresholdPolicy(
            address(provider),
            deployer
        );
        console.log("ThresholdPolicy:", address(threshold));

        // 3. Deploy RegionalPolicy (EU/regional pools)
        RegionalPolicy regional = new RegionalPolicy(
            address(provider),
            deployer
        );
        console.log("RegionalPolicy:", address(regional));

        // 4. Deploy InstitutionalPolicy (multi-provider pools)
        InstitutionalPolicy institutional = new InstitutionalPolicy(deployer);
        console.log("InstitutionalPolicy:", address(institutional));

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Next: Deploy LexifiHook with CREATE2 salt mining");
        console.log("Run: forge script script/DeployHook.s.sol --rpc-url https://sepolia.base.org --broadcast");
    }
}
