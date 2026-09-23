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
        // Key optional: leave PRIVATE_KEY unset and pass --account <keystore> --sender <addr>.
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = deployerKey != 0 ? vm.addr(deployerKey) : msg.sender;
        address poolManager = vm.envAddress("POOL_MANAGER");
        address owner = vm.envAddress("OWNER"); // Smart Wallet or Safe
        // Optional: leave HOOK_SALT unset and this script mines the salt itself.
        bytes32 salt = vm.envOr("HOOK_SALT", bytes32(0));
        require(owner != deployer, "OWNER must differ from throwaway deployer");

        console.log("Deployer (throwaway):", deployer);
        console.log("Owner (Smart Wallet/Safe):", owner);
        console.log("PoolManager:", poolManager);
        console.logBytes32(salt);

        bytes memory creationCode =
            abi.encodePacked(type(LexifiHook).creationCode, abi.encode(IPoolManager(poolManager), owner));

        // Mine here rather than in MineSalt.s.sol when no salt is given. `type(X).creationCode`
        // is not guaranteed to be byte-identical across compilation units, so a salt mined in a
        // different script can predict a different address than the one this script deploys to.
        // Mining against the very bytes we are about to send removes that whole class of error.
        // A salt is only usable if the address it produces carries the hook's permission bits.
        // HOOK_SALT often arrives stale from .env (it holds the salt of an earlier chain's
        // deploy), so check it and mine a correct one rather than failing.
        if (salt == bytes32(0) || !_fits(_predict(salt, keccak256(creationCode)))) {
            if (salt != bytes32(0)) {
                console.log("HOOK_SALT does not fit this chain/owner; mining a new one.");
            }
            salt = _mine(keccak256(creationCode));
            console.log("Mined salt:");
            console.logBytes32(salt);
        }

        address predicted = _predict(salt, keccak256(creationCode));
        console.log("Predicted hook address:", predicted);
        require(_fits(predicted), "Wrong permission bits! Re-mine salt.");

        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast();
        }
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

    function _predict(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initCodeHash))
                )
            )
        );
    }

    /// @dev True when the address encodes exactly this hook's permissions.
    function _fits(address a) internal pure returns (bool) {
        uint160 required =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG);
        return (uint160(a) & uint160((1 << 14) - 1)) == required;
    }

    /// @dev Finds a salt whose CREATE2 address carries exactly the hook's permission bits.
    function _mine(bytes32 initCodeHash) internal pure returns (bytes32) {
        for (uint256 i = 0; i < 2_000_000; i++) {
            if (_fits(_predict(bytes32(i), initCodeHash))) return bytes32(i);
        }
        revert("No salt found in 2M iterations");
    }
}
