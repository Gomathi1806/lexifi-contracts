// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LexifiHook} from "../src/LexifiHook.sol";

/// @notice Deploys LexifiHook via CREATE2 with the mined salt.
///         Run MineSalt first to find the correct salt, then set HOOK_SALT env var.
contract DeployHook is Script {
    // Standard deterministic CREATE2 deployer (present on all EVM chains)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address poolManager = vm.envAddress("POOL_MANAGER");
        bytes32 salt = vm.envBytes32("HOOK_SALT");

        console.log("Deployer:", deployer);
        console.log("PoolManager:", poolManager);
        console.logBytes32(salt);

        // Predict the address
        bytes memory creationCode = abi.encodePacked(
            type(LexifiHook).creationCode,
            abi.encode(IPoolManager(poolManager), deployer)
        );

        address predicted = address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, keccak256(creationCode))
        ))));

        console.log("Predicted hook address:", predicted);
        console.log("Address flags:", uint16(uint160(predicted)));

        // Verify flags
        uint160 flags = uint160(predicted) & uint160((1 << 14) - 1);
        uint160 required = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG);

        require(flags == required, "Wrong permission bits! Re-mine salt.");

        vm.startBroadcast(deployerKey);

        // Deploy via CREATE2
        bytes memory payload = abi.encodePacked(salt, creationCode);
        (bool success,) = CREATE2_DEPLOYER.call(payload);
        require(success, "CREATE2 deployment failed");

        console.log("");
        console.log("=== LexifiHook deployed at:", predicted, "===");

        vm.stopBroadcast();
    }
}
