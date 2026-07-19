// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Minimal mock PoolManager for unit testing hooks.
/// @dev Only needs to exist at an address so the hook's onlyPoolManager modifier passes.
///      In tests, use vm.prank(address(mockPoolManager)) to call hook functions.
contract MockPoolManager {
    // Intentionally empty — we only need this contract's address
    // for the onlyPoolManager check in the hook.
    // Full integration tests would use Uniswap's test helpers.
}
