// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LexifiHook} from "../src/LexifiHook.sol";

/// @notice Deploys LexifiHook via the canonical CREATE2 factory with the mined salt.
///         Owner is the OWNER env address (Smart Wallet / Safe), never the deployer key.
///         Run MineSalt first; set HOOK_SALT to its output.
contract DeployHook is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address poolManager = vm.envAddress("POOL_MANAGER");
        address owner = vm.envAddress("OWNER"); // Smart Wallet or Safe
        bytes32 salt = vm.envBytes32("HOOK_SALT");
        require(owner != deployer, "OWNER must differ from throwaway deployer");

        console.log("Deployer (throwaway):", deployer);
        console.log("Owner (Smart Wallet/Safe):", owner);
        console.log("PoolManager:", poolManager);
        console.logBytes32(salt);

        bytes memory creationCode =
            abi.encodePacked(type(LexifiHook).creationCode, abi.encode(IPoolManager(poolManager), owner));

        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, keccak256(creationCode))
                    )
                )
            )
        );
        console.log("Predicted hook address:", predicted);

        uint160 flags = uint160(predicted) & uint160((1 << 14) - 1);
        uint160 required =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG);
        require(flags == required, "Wrong permission bits! Re-mine salt.");

        vm.startBroadcast(deployerKey);
        (bool success,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, creationCode));
        require(success, "CREATE2 deployment failed");
        vm.stopBroadcast();

        require(predicted.code.length > 0, "No code at predicted address");
        console.log("");
        console.log("=== LexifiHook deployed at:", predicted, "===");
        console.log("Owner:", owner);
        console.log("Next steps (from the OWNER wallet):");
        console.log("  1. setTrustedRouter(UniversalRouter, true)");
        console.log("  2. setTrustedRouter(PositionManager, true)");
    }
}
