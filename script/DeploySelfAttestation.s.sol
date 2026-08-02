// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {SelfAttestationProvider} from "../src/policies/SelfAttestationProvider.sol";

/// @notice Standalone deploy for SelfAttestationProvider.
///         OWNER (Safe multisig) controls the provider — NOT the deployer key.
contract DeploySelfAttestation is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address owner = vm.envAddress("OWNER");
        require(owner != deployer, "OWNER must differ from throwaway deployer");

        console.log("Deployer (throwaway):", deployer);
        console.log("Owner (Safe):", owner);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerKey);

        SelfAttestationProvider selfAttest = new SelfAttestationProvider(owner, "Lexifi Operator KYC");
        console.log("SelfAttestationProvider:", address(selfAttest));

        vm.stopBroadcast();

        console.log("");
        console.log("=== SelfAttestationProvider DEPLOYED ===");
        console.log("Owner:", owner);
        console.log("Update lexifi-sdk/src/addresses.ts with the address above.");
    }
}
