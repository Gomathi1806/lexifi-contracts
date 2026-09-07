// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ILexifiPolicy} from "../src/interfaces/ILexifiPolicy.sol";
import {LexifiPolicyConfig} from "../src/LexifiPolicyConfig.sol";
import {RegionalPolicyV3} from "../src/policies/RegionalPolicyV3.sol";
import {InstitutionalPolicyV3} from "../src/policies/InstitutionalPolicyV3.sol";

interface ILegacyRegionalPolicy {
    function regionConfigs(PoolId)
        external
        view
        returns (
            bool requireCountryAttestation,
            bool requireAccountAttestation,
            ILexifiPolicy.AccessLevel minimumSwapLevel,
            ILexifiPolicy.AccessLevel minimumLpLevel,
            bool active
        );
}

/// @notice Deploys LexifiPolicyConfig + the registry-backed V3 policies, and migrates the live
///         RegionalPolicy config into the registry (audit options B, C and D).
///
/// @dev **Everything this script does is additive.** Deploying contracts and seeding registry
///      config changes nothing about how the live pool behaves — the pool keeps pointing at
///      RegionalPolicy v1 until someone calls `setPoolPolicy`. That re-point is deliberately
///      NOT done here: it is the one step that alters a live pool, and it should be run
///      knowingly, after verifying the migrated config reads back correctly.
///
///      Migration is done on-chain rather than by retyping values, so the registry cannot
///      disagree with what v1 actually holds.
contract DeployPolicyRegistry is Script {
    address constant LIVE_PROVIDER = 0xb5DEC225A104A276671A765aba3890EC88A2ca27;
    address constant LIVE_REGIONAL_V1 = 0xA99A89Cd5A61e975fB11047D3ed455fCCad9A44F;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address owner = vm.envAddress("OWNER");
        address provider = vm.envOr("COINBASE_PROVIDER", LIVE_PROVIDER);

        // Pool whose v1 config should be carried into the registry. Optional: unset means
        // deploy only, migrate nothing.
        bytes32 migratePoolId = vm.envOr("MIGRATE_POOL_ID", bytes32(0));
        address legacyRegional = vm.envOr("LEGACY_REGIONAL", LIVE_REGIONAL_V1);

        require(owner != deployer, "OWNER must differ from deployer");
        require(provider.code.length > 0, "provider has no code on this chain");

        console.log("Chain ID:  ", block.chainid);
        console.log("Deployer:  ", deployer);
        console.log("Owner:     ", owner);
        console.log("Provider:  ", provider);

        // Read the legacy config BEFORE broadcasting, so the migrated values come from chain
        // state rather than from anything typed into this script.
        bool hasLegacy;
        bytes memory migratedConfig;
        if (migratePoolId != bytes32(0)) {
            (bool c, bool a, ILexifiPolicy.AccessLevel s, ILexifiPolicy.AccessLevel l, bool act) =
                ILegacyRegionalPolicy(legacyRegional).regionConfigs(PoolId.wrap(migratePoolId));
            require(act, "legacy pool config is not active - nothing to migrate");
            hasLegacy = true;

            console.log("");
            console.log("Legacy config read from", legacyRegional);
            console.log("  requireCountry: ", c);
            console.log("  requireAccount: ", a);
            console.log("  minSwapLevel:   ", uint8(s));
            console.log("  minLpLevel:     ", uint8(l));

            migratedConfig = abi.encode(
                RegionalPolicyV3.RegionConfig({
                    requireCountryAttestation: c,
                    requireAccountAttestation: a,
                    minimumSwapLevel: s,
                    minimumLpLevel: l,
                    active: true
                })
            );
        }

        vm.startBroadcast(deployerKey);

        LexifiPolicyConfig registry = new LexifiPolicyConfig();
        RegionalPolicyV3 regional = new RegionalPolicyV3(provider, address(registry), owner);
        InstitutionalPolicyV3 institutional = new InstitutionalPolicyV3(address(registry), owner);

        if (hasLegacy) {
            registry.setConfig(
                regional.CONFIG_FAMILY(), PoolId.wrap(migratePoolId), migratedConfig
            );
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYED ===");
        console.log("LexifiPolicyConfig:  ", address(registry));
        console.log("RegionalPolicyV3:    ", address(regional));
        console.log("InstitutionalPolicyV3:", address(institutional));

        if (hasLegacy) {
            console.log("");
            console.log("Migrated config for pool:");
            console.logBytes32(migratePoolId);
            console.log("Registry pool admin is now the deployer. To hand it to the Safe:");
            console.log("  registry.transferPoolAdmin(family, poolId, OWNER)");
        }

        console.log("");
        console.log("--- NOTHING IS LIVE YET ---");
        console.log("The pool still points at RegionalPolicy v1. To cut over, the POOL ADMIN");
        console.log("calls LexifiHook.setPoolPolicy(poolKey, RegionalPolicyV3).");
        console.log("Verify FIRST that effectiveConfig() matches v1, then re-point.");
        console.log("");
        console.log("WARNING: V3 denies unconfigured pools. Any OTHER pool re-pointed at these");
        console.log("policies without registry config will stop trading until configured.");
    }
}
