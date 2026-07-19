// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LexifiHook} from "../src/LexifiHook.sol";

/// @notice Mines a CREATE2 salt so LexifiHook lands on an address whose low 14 bits
///         encode exactly: beforeInitialize | beforeAddLiquidity | beforeSwap (0x2880).
/// @dev The factory MUST be the canonical CREATE2 deployer used by DeployHook —
///      the factory address is part of the CREATE2 formula. (The previous version
///      of this script mined against the deployer EOA, which predicts the wrong
///      address; that bug is fixed here.)
contract MineSalt is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 constant REQUIRED_FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG);
    uint160 constant ALL_FLAGS = uint160((1 << 14) - 1);

    function run() external view {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address owner = vm.envAddress("OWNER"); // Smart Wallet or Safe

        console.log("Mining CREATE2 salt for LexifiHook...");
        console.log("Factory:", CREATE2_DEPLOYER);
        console.log("PoolManager:", poolManager);
        console.log("Owner:", owner);

        bytes memory creationCode =
            abi.encodePacked(type(LexifiHook).creationCode, abi.encode(IPoolManager(poolManager), owner));
        bytes32 initCodeHash = keccak256(creationCode);
        console.log("InitCode hash:");
        console.logBytes32(initCodeHash);

        for (uint256 salt = 0; salt < 2_000_000; salt++) {
            address predicted = _computeAddress(CREATE2_DEPLOYER, bytes32(salt), initCodeHash);
            if (uint160(predicted) & ALL_FLAGS == REQUIRED_FLAGS) {
                console.log("");
                console.log("=== FOUND ===");
                console.log("Salt:", salt);
                console.logBytes32(bytes32(salt));
                console.log("Hook address:", predicted);
                console.log("Set HOOK_SALT to the bytes32 above and run DeployHook.");
                return;
            }
        }
        revert("No salt found in 2M iterations; widen the range.");
    }

    function _computeAddress(address factory, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initCodeHash))))
        );
    }
}
