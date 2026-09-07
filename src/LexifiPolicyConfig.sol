// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title LexifiPolicyConfig
/// @notice Shared, policy-external store for per-pool policy configuration.
///
/// @dev **Why this exists.** Policy contracts are immutable, so fixing a bug in one means
///      redeploying it. Before this registry, each policy kept its config in its own storage —
///      and storage belongs to one address, so a redeploy started blank. Every fix therefore
///      required re-entering every pool's config by hand, and a pool re-pointed at a fresh
///      policy without that step read as *unconfigured*, which the policies treated as OPEN
///      ACCESS. A missed migration silently switched compliance off.
///
///      Config here is keyed by `(family, poolId)`, **not** by policy address. `family` is a
///      constant a policy declares (`keccak256("lexifi.policy.regional")`) and keeps across
///      logic versions, so RegionalPolicy v3, v4 and v5 all read the same config. Redeploying
///      policy logic no longer touches configuration at all.
///
///      **Storage is opaque `bytes`.** The registry never decodes; each policy family owns its
///      own struct layout and `abi.decode`s what it wrote. That keeps the registry generic — a
///      new policy type needs no change here — at the cost of the registry being unable to
///      validate contents. Validation is therefore the reading policy's job, and policies MUST
///      treat decoded config as untrusted (see `RegionalPolicy._config`, which clamps
///      `minLp` up to `minSwap` at read time rather than trusting the stored ordering).
///
///      **Access control** mirrors the policies it replaces: first writer for a
///      `(family, poolId)` becomes its admin, and only that admin may update or clear it.
///      There is deliberately no global owner override — a Safe that could rewrite any pool's
///      compliance config would be exactly the admin key this stack avoids having.
contract LexifiPolicyConfig {
    /// @dev family => poolId => abi-encoded config owned by that policy family.
    mapping(bytes32 => mapping(PoolId => bytes)) private _config;

    /// @notice First address to write a given (family, poolId); the only one that may change it.
    mapping(bytes32 => mapping(PoolId => address)) public poolAdmin;

    event ConfigSet(bytes32 indexed family, PoolId indexed poolId, address indexed admin, bytes data);
    event ConfigCleared(bytes32 indexed family, PoolId indexed poolId, address indexed admin);
    event PoolAdminTransferred(
        bytes32 indexed family, PoolId indexed poolId, address indexed from, address to
    );

    error Unauthorized();
    error EmptyConfig();
    error LengthMismatch();
    error ZeroAddress();

    /// @notice Write (or overwrite) the config for one pool under one policy family.
    /// @dev Empty data is rejected: `isConfigured` uses length, so storing nothing would be
    ///      indistinguishable from never having configured the pool — and policies deny on
    ///      unconfigured. Use `clearConfig` to deliberately remove.
    function setConfig(bytes32 family, PoolId poolId, bytes calldata data) public {
        if (data.length == 0) revert EmptyConfig();
        address admin = poolAdmin[family][poolId];
        if (admin != address(0) && admin != msg.sender) revert Unauthorized();

        _config[family][poolId] = data;
        if (admin == address(0)) poolAdmin[family][poolId] = msg.sender;

        emit ConfigSet(family, poolId, msg.sender, data);
    }

    /// @notice Write several pools in one transaction.
    /// @dev The point of this is migration: re-pointing pools to a redeployed policy and seeding
    ///      their config should land in a single atomic step, so there is no window in which a
    ///      pool is live against an unconfigured policy.
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
        if (poolAdmin[family][poolId] != msg.sender) revert Unauthorized();
        delete _config[family][poolId];
        emit ConfigCleared(family, poolId, msg.sender);
    }

    /// @notice Hand a pool's config rights to another address (e.g. EOA -> Safe).
    function transferPoolAdmin(bytes32 family, PoolId poolId, address newAdmin) external {
        if (poolAdmin[family][poolId] != msg.sender) revert Unauthorized();
        if (newAdmin == address(0)) revert ZeroAddress();
        poolAdmin[family][poolId] = newAdmin;
        emit PoolAdminTransferred(family, poolId, msg.sender, newAdmin);
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
