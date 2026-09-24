// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @notice The one getter this registry needs from the hook.
interface IPoolAdminSource {
    function poolAdmin(PoolId poolId) external view returns (address);
}

/// @title LexifiPolicyConfigV2
/// @notice Per-pool policy configuration, writable only by the pool's admin on the hook.
/// @dev **What changed from LexifiPolicyConfig.** V1 kept its own admin per `(family, poolId)`
///      and gave it to the first writer, so anyone could claim the config slot of a pool they
///      did not control, including one that did not exist yet. V2 keeps no admin of its own: a
///      write is allowed only if the caller is `hook.poolAdmin(poolId)` at that moment. The
///      hook (LexifiHookV3) sets that admin at pool creation, so there is no slot to claim,
///      and a transfer of pool admin on the hook moves config rights with it.
///
///      Storage and reads are unchanged: opaque `bytes` keyed by `(family, poolId)`, read with
///      `getConfig` / `isConfigured`, so RegionalPolicyV3 and InstitutionalPolicyV3 work with
///      this registry without a code change (redeploy them with this address).
///
///      There is still no global owner override.
contract LexifiPolicyConfigV2 {
    /// @notice The hook whose pool admins control config here.
    IPoolAdminSource public immutable hook;

    /// @dev family => poolId => abi-encoded config owned by that policy family.
    mapping(bytes32 => mapping(PoolId => bytes)) private _config;

    event ConfigSet(bytes32 indexed family, PoolId indexed poolId, address indexed admin, bytes data);
    event ConfigCleared(bytes32 indexed family, PoolId indexed poolId, address indexed admin);

    error Unauthorized();
    error EmptyConfig();
    error LengthMismatch();
    error ZeroAddress();

    constructor(IPoolAdminSource _hook) {
        if (address(_hook) == address(0)) revert ZeroAddress();
        hook = _hook;
    }

    /// @notice The address allowed to write this pool's config: its admin on the hook.
    function poolAdmin(PoolId poolId) public view returns (address) {
        return hook.poolAdmin(poolId);
    }

    function _checkAdmin(PoolId poolId) internal view {
        address admin = hook.poolAdmin(poolId);
        if (admin == address(0) || admin != msg.sender) revert Unauthorized();
    }

    /// @notice Write (or overwrite) the config for one pool under one policy family.
    /// @dev Empty data is rejected; use `clearConfig` to remove.
    function setConfig(bytes32 family, PoolId poolId, bytes calldata data) public {
        if (data.length == 0) revert EmptyConfig();
        _checkAdmin(poolId);
        _config[family][poolId] = data;
        emit ConfigSet(family, poolId, msg.sender, data);
    }

    /// @notice Write several pools in one transaction.
    function setConfigBatch(bytes32 family, PoolId[] calldata poolIds, bytes[] calldata datas)
        external
    {
        if (poolIds.length != datas.length) revert LengthMismatch();
        for (uint256 i = 0; i < poolIds.length; i++) {
            setConfig(family, poolIds[i], datas[i]);
        }
    }

    /// @notice Remove a pool's config. Policies deny on unconfigured pools, so this is a kill
    ///         switch, not a reset to open access.
    function clearConfig(bytes32 family, PoolId poolId) external {
        _checkAdmin(poolId);
        delete _config[family][poolId];
        emit ConfigCleared(family, poolId, msg.sender);
    }

    /// @notice Raw config bytes; empty when the pool was never configured for this family.
    function getConfig(bytes32 family, PoolId poolId) external view returns (bytes memory) {
        return _config[family][poolId];
    }

    /// @notice Whether this pool has config under this family. Policies deny when false.
    function isConfigured(bytes32 family, PoolId poolId) external view returns (bool) {
        return _config[family][poolId].length != 0;
    }
}
