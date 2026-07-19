// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LexifiHook} from "../src/LexifiHook.sol";

/// @notice Mines a CREATE2 salt so the LexifiHook deploys to an address
///         with the correct permission bits in the last 2 bytes.
///
///         Required flags:
///         - beforeInitialize  (bit 13) = 0x2000
///         - beforeAddLiquidity (bit 11) = 0x0800
///         - beforeSwap        (bit 7)  = 0x0080
///         Combined mask: 0x2880
///
///         The address must have these bits SET and no other hook bits set.
contract MineSalt is Script {
    // Hook permission flags we need
    uint160 constant REQUIRED_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG |
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
        Hooks.BEFORE_SWAP_FLAG
    );

    // All possible hook flags (last 14 bits)
    uint160 constant ALL_FLAGS = uint160((1 << 14) - 1);

    function run() external view {
        // Read from environment
        address poolManager = vm.envAddress("POOL_MANAGER");
        address owner = vm.envAddress("DEPLOYER");

        console.log("Mining CREATE2 salt for LexifiHook...");
        console.log("PoolManager:", poolManager);
        console.log("Owner:", owner);
        console.log("Required flags: 0x2880");
        console.log("");

        // Get the creation code with constructor args
        bytes memory creationCode = abi.encodePacked(
            type(LexifiHook).creationCode,
            abi.encode(IPoolManager(poolManager), owner)
        );

        bytes32 initCodeHash = keccak256(creationCode);
        console.log("InitCode hash:");
        console.logBytes32(initCodeHash);

        // Mine salt using CREATE2 formula:
        // address = keccak256(0xff ++ deployer ++ salt ++ keccak256(creationCode))[12:]
        // We use the deployer's address as the CREATE2 deployer
        // For simplicity, we'll mine using address(deployer) as the factory

        bool found = false;
        for (uint256 salt = 0; salt < 100000; salt++) {
            address predicted = _computeAddress(owner, bytes32(salt), initCodeHash);

            uint160 addrFlags = uint160(predicted) & ALL_FLAGS;

            // Must have ALL required flags and NO extra flags
            if (addrFlags == REQUIRED_FLAGS) {
                console.log("");
                console.log("=== FOUND ===");
                console.log("Salt:", salt);
                console.logBytes32(bytes32(salt));
                console.log("Hook address:", predicted);
                console.log("Last 2 bytes:", uint16(uint160(predicted)));
                found = true;
                break;
            }
        }

        if (!found) {
            console.log("");
            console.log("No salt found in 100k iterations.");
            console.log("Try running with higher range or different deployer.");
        }
    }

    function _computeAddress(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (address) {
        return address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)
        ))));
    }
}
