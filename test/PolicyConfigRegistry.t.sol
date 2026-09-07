// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LexifiHook} from "../src/LexifiHook.sol";
import {ILexifiPolicy} from "../src/interfaces/ILexifiPolicy.sol";
import {LexifiPolicyConfig} from "../src/LexifiPolicyConfig.sol";
import {RegionalPolicy} from "../src/policies/RegionalPolicy.sol";
import {RegionalPolicyV3} from "../src/policies/RegionalPolicyV3.sol";
import {InstitutionalPolicyV3} from "../src/policies/InstitutionalPolicyV3.sol";
import {LexifiComplianceAdapter} from "../src/integrations/LexifiComplianceAdapter.sol";
import {MockVerificationProvider} from "./mocks/MockVerificationProvider.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

/// @title Registry-backed policy config — options B, C and D
/// @dev Assertions go through the real enforcement comparison via LexifiComplianceAdapter,
///      never through `checkAccess` alone.
contract PolicyConfigRegistryTest is Test {
    using PoolIdLibrary for PoolKey;

    MockPoolManager poolManager;
    LexifiHook hook;
    LexifiComplianceAdapter adapter;
    LexifiPolicyConfig registry;
    RegionalPolicyV3 regionalV3;
    InstitutionalPolicyV3 institutionalV3;
    MockVerificationProvider provider;
    MockVerificationProvider provider2;

    address owner = address(0xCAFE);
    address stranger = address(0xBAD);
    address retailUser = address(0x1111);
    address accreditedUser = address(0x2222);

    PoolKey regionalKey;
    PoolKey institutionalKey;
    bytes32 regionalPoolId;
    bytes32 institutionalPoolId;

    uint8 constant OP_SWAP = 0;
    uint8 constant OP_LP = 1;

    function setUp() public {
        vm.startPrank(owner);
        poolManager = new MockPoolManager();
        hook = new LexifiHook(IPoolManager(address(poolManager)), owner);
        adapter = new LexifiComplianceAdapter(address(hook));
        registry = new LexifiPolicyConfig();
        provider = new MockVerificationProvider();
        provider2 = new MockVerificationProvider();

        regionalV3 = new RegionalPolicyV3(address(provider), address(registry), owner);
        institutionalV3 = new InstitutionalPolicyV3(address(registry), owner);

        regionalKey = _key(3000);
        institutionalKey = _key(500);
        regionalPoolId = PoolId.unwrap(regionalKey.toId());
        institutionalPoolId = PoolId.unwrap(institutionalKey.toId());

        hook.setPoolPolicy(regionalKey, address(regionalV3));
        hook.setPoolPolicy(institutionalKey, address(institutionalV3));

        provider.setUser(retailUser, 1, true);
        provider.setUser(accreditedUser, 2, true);
        vm.stopPrank();
    }

    function _key(uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x4200000000000000000000000000000000000006)),
            currency1: Currency.wrap(address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _allowed(bytes32 poolId, address user, uint8 op) internal view returns (bool) {
        (bool allowed,,,) = adapter.checkCompliance(poolId, user, op, 0);
        return allowed;
    }

    function _setRegional(
        bool reqCountry,
        bool reqAccount,
        ILexifiPolicy.AccessLevel minSwap,
        ILexifiPolicy.AccessLevel minLp
    ) internal {
        // Resolve every other external call FIRST. vm.prank only covers the next external call,
        // so calling CONFIG_FAMILY()/encodeConfig() inline would consume it and leave setConfig
        // running as the test contract.
        bytes32 family = regionalV3.CONFIG_FAMILY();
        bytes memory data = regionalV3.encodeConfig(reqCountry, reqAccount, minSwap, minLp);
        vm.prank(owner);
        registry.setConfig(family, regionalKey.toId(), data);
    }

    // ═══════════════════════════════════════════
    //  OPTION D — unconfigured must fail closed
    // ═══════════════════════════════════════════

    /// @dev The whole point of D. Under v1 this returned INSTITUTIONAL and the pool traded
    ///      freely — a pool re-pointed to a fresh policy without its config silently lost
    ///      compliance. It must now deny.
    function test_D_UnconfiguredPool_Denied_Regional() public view {
        assertFalse(registry.isConfigured(regionalV3.CONFIG_FAMILY(), regionalKey.toId()));
        assertFalse(_allowed(regionalPoolId, accreditedUser, OP_SWAP), "swap must be denied");
        assertFalse(_allowed(regionalPoolId, accreditedUser, OP_LP), "LP must be denied");
    }

    function test_D_UnconfiguredPool_Denied_Institutional() public view {
        assertFalse(_allowed(institutionalPoolId, accreditedUser, OP_SWAP));
        assertFalse(_allowed(institutionalPoolId, accreditedUser, OP_LP));
    }

    /// @dev The denial must be legible, not a bare false.
    function test_D_UnconfiguredPool_ReasonIsExplicit() public view {
        (, string memory reason) =
            regionalV3.checkAccess(regionalKey.toId(), accreditedUser, OP_SWAP, 0);
        assertEq(reason, "Pool not configured for this policy");
    }

    /// @dev active=false is treated as unconfigured, not as open access.
    function test_D_InactiveConfig_Denied() public {
        bytes32 family = regionalV3.CONFIG_FAMILY();
        vm.prank(owner);
        registry.setConfig(
            family,
            regionalKey.toId(),
            abi.encode(
                RegionalPolicyV3.RegionConfig({
                    requireCountryAttestation: false,
                    requireAccountAttestation: false,
                    minimumSwapLevel: ILexifiPolicy.AccessLevel.DENIED,
                    minimumLpLevel: ILexifiPolicy.AccessLevel.DENIED,
                    active: false
                })
            )
        );
        assertFalse(_allowed(regionalPoolId, accreditedUser, OP_SWAP));
    }

    /// @dev Clearing config must deny, not reopen the pool.
    function test_D_ClearingConfigDenies() public {
        _setRegional(false, false, ILexifiPolicy.AccessLevel.RETAIL, ILexifiPolicy.AccessLevel.RETAIL);
        assertTrue(_allowed(regionalPoolId, retailUser, OP_SWAP));

        bytes32 family = regionalV3.CONFIG_FAMILY();
        vm.prank(owner);
        registry.clearConfig(family, regionalKey.toId());
        assertFalse(_allowed(regionalPoolId, retailUser, OP_SWAP), "cleared must deny");
    }

    // ═══════════════════════════════════════════
    //  OPTION C — config survives a policy redeploy
    // ═══════════════════════════════════════════

    /// @dev The reason the registry exists: deploy fresh policy logic, point the pool at it,
    ///      and the pool keeps working with no migration step at all.
    function test_C_ConfigSurvivesPolicyRedeploy() public {
        _setRegional(
            true, false, ILexifiPolicy.AccessLevel.ACCREDITED, ILexifiPolicy.AccessLevel.ACCREDITED
        );
        assertTrue(_allowed(regionalPoolId, accreditedUser, OP_SWAP));
        assertFalse(_allowed(regionalPoolId, retailUser, OP_SWAP));

        // Ship "v4": brand-new address, zero storage, same CONFIG_FAMILY.
        RegionalPolicyV3 redeployed =
            new RegionalPolicyV3(address(provider), address(registry), owner);
        assertTrue(address(redeployed) != address(regionalV3));
        vm.prank(owner);
        hook.setPoolPolicy(regionalKey, address(redeployed));

        // No setConfig was called against the new policy — behaviour is identical anyway.
        assertTrue(_allowed(regionalPoolId, accreditedUser, OP_SWAP), "config carried over");
        assertFalse(_allowed(regionalPoolId, retailUser, OP_SWAP), "and still gates");
    }

    /// @dev Families are namespaced: two policy types cannot read each other's bytes.
    function test_C_FamiliesAreIsolated() public {
        _setRegional(false, false, ILexifiPolicy.AccessLevel.RETAIL, ILexifiPolicy.AccessLevel.RETAIL);

        assertTrue(registry.isConfigured(regionalV3.CONFIG_FAMILY(), regionalKey.toId()));
        assertFalse(
            registry.isConfigured(institutionalV3.CONFIG_FAMILY(), regionalKey.toId()),
            "institutional family must be untouched"
        );
    }

    // ═══════════════════════════════════════════
    //  Registry access control
    // ═══════════════════════════════════════════

    function test_Registry_FirstWriterBecomesAdmin() public {
        _setRegional(false, false, ILexifiPolicy.AccessLevel.RETAIL, ILexifiPolicy.AccessLevel.RETAIL);
        assertEq(registry.poolAdmin(regionalV3.CONFIG_FAMILY(), regionalKey.toId()), owner);
    }

    function test_Registry_StrangerCannotOverwrite() public {
        _setRegional(false, false, ILexifiPolicy.AccessLevel.RETAIL, ILexifiPolicy.AccessLevel.RETAIL);

        bytes32 family = regionalV3.CONFIG_FAMILY();
        bytes memory data = regionalV3.encodeConfig(
            false, false, ILexifiPolicy.AccessLevel.DENIED, ILexifiPolicy.AccessLevel.DENIED
        );
        vm.prank(stranger);
        vm.expectRevert(LexifiPolicyConfig.Unauthorized.selector);
        registry.setConfig(family, regionalKey.toId(), data);
    }

    function test_Registry_StrangerCannotClearOrTransfer() public {
        _setRegional(false, false, ILexifiPolicy.AccessLevel.RETAIL, ILexifiPolicy.AccessLevel.RETAIL);

        bytes32 family = regionalV3.CONFIG_FAMILY();
        vm.startPrank(stranger);
        vm.expectRevert(LexifiPolicyConfig.Unauthorized.selector);
        registry.clearConfig(family, regionalKey.toId());
        vm.expectRevert(LexifiPolicyConfig.Unauthorized.selector);
        registry.transferPoolAdmin(family, regionalKey.toId(), stranger);
        vm.stopPrank();
    }

    function test_Registry_AdminTransfer() public {
        _setRegional(false, false, ILexifiPolicy.AccessLevel.RETAIL, ILexifiPolicy.AccessLevel.RETAIL);
        bytes32 family = regionalV3.CONFIG_FAMILY();
        vm.prank(owner);
        registry.transferPoolAdmin(family, regionalKey.toId(), stranger);
        assertEq(registry.poolAdmin(regionalV3.CONFIG_FAMILY(), regionalKey.toId()), stranger);

        // Old admin is now locked out.
        vm.prank(owner);
        vm.expectRevert(LexifiPolicyConfig.Unauthorized.selector);
        registry.clearConfig(family, regionalKey.toId());
    }

    function test_Registry_RejectsEmptyConfig() public {
        bytes32 family = regionalV3.CONFIG_FAMILY();
        vm.prank(owner);
        vm.expectRevert(LexifiPolicyConfig.EmptyConfig.selector);
        registry.setConfig(family, regionalKey.toId(), "");
    }

    function test_Registry_BatchLengthMismatch() public {
        PoolId[] memory ids = new PoolId[](2);
        bytes[] memory datas = new bytes[](1);
        bytes32 family = regionalV3.CONFIG_FAMILY();
        vm.prank(owner);
        vm.expectRevert(LexifiPolicyConfig.LengthMismatch.selector);
        registry.setConfigBatch(family, ids, datas);
    }

    /// @dev Migration lands in one transaction, so no pool is ever live against an
    ///      unconfigured policy.
    function test_B_BatchMigrationIsAtomic() public {
        PoolKey memory second = _key(10000);
        PoolId[] memory ids = new PoolId[](2);
        ids[0] = regionalKey.toId();
        ids[1] = second.toId();

        bytes[] memory datas = new bytes[](2);
        datas[0] = regionalV3.encodeConfig(
            false, false, ILexifiPolicy.AccessLevel.RETAIL, ILexifiPolicy.AccessLevel.RETAIL
        );
        datas[1] = regionalV3.encodeConfig(
            true, false, ILexifiPolicy.AccessLevel.ACCREDITED, ILexifiPolicy.AccessLevel.ACCREDITED
        );
        bytes32 family = regionalV3.CONFIG_FAMILY();

        vm.startPrank(owner);
        registry.setConfigBatch(family, ids, datas);
        hook.setPoolPolicy(second, address(regionalV3));
        vm.stopPrank();

        assertTrue(_allowed(regionalPoolId, retailUser, OP_SWAP));
        assertFalse(_allowed(PoolId.unwrap(second.toId()), retailUser, OP_SWAP));
        assertTrue(_allowed(PoolId.unwrap(second.toId()), accreditedUser, OP_SWAP));
    }

    // ═══════════════════════════════════════════
    //  OPTION B — migrated config must behave identically to the legacy policy
    // ═══════════════════════════════════════════

    /// @dev This is the check that makes a live re-point safe: for the exact config on Base
    ///      mainnet today (requireCountry=true, minSwap=minLp=ACCREDITED), legacy v1 and the
    ///      migrated v3 must agree on every user and both operations.
    function test_B_MigratedConfigMatchesLegacyBehaviour() public {
        vm.startPrank(owner);

        // Stand up legacy v1 with the live mainnet config.
        RegionalPolicy legacy = new RegionalPolicy(address(provider), owner);
        PoolKey memory legacyKey = _key(100);
        legacy.setRegionConfig(
            legacyKey.toId(),
            true,
            false,
            ILexifiPolicy.AccessLevel.ACCREDITED,
            ILexifiPolicy.AccessLevel.ACCREDITED
        );
        hook.setPoolPolicy(legacyKey, address(legacy));
        vm.stopPrank();

        // Migrate the same values into the registry for the v3 pool.
        _setRegional(
            true, false, ILexifiPolicy.AccessLevel.ACCREDITED, ILexifiPolicy.AccessLevel.ACCREDITED
        );

        bytes32 legacyPoolId = PoolId.unwrap(legacyKey.toId());
        address[3] memory users = [retailUser, accreditedUser, address(0xDEAD)];

        for (uint256 i = 0; i < users.length; i++) {
            assertEq(
                _allowed(legacyPoolId, users[i], OP_SWAP),
                _allowed(regionalPoolId, users[i], OP_SWAP),
                "swap verdict must match legacy"
            );
            assertEq(
                _allowed(legacyPoolId, users[i], OP_LP),
                _allowed(regionalPoolId, users[i], OP_LP),
                "LP verdict must match legacy"
            );
        }
    }

    // ═══════════════════════════════════════════
    //  Finding fixes still hold on the V3 path
    // ═══════════════════════════════════════════

    /// @dev Finding 1, now enforced by read-time clamping because the registry stores opaque
    ///      bytes and cannot reject a bad ordering at write time.
    function test_Finding1_MinLpClampedUpToMinSwap() public {
        _setRegional(
            false, false, ILexifiPolicy.AccessLevel.ACCREDITED, ILexifiPolicy.AccessLevel.RETAIL
        );

        assertFalse(regionalV3.validateConfig(regionalKey.toId()), "stored ordering is unsafe");

        (RegionalPolicyV3.RegionConfig memory cfg,) = regionalV3.effectiveConfig(regionalKey.toId());
        assertEq(
            uint8(cfg.minimumLpLevel),
            uint8(ILexifiPolicy.AccessLevel.ACCREDITED),
            "clamped up to minSwap"
        );

        // The backdoor is closed despite the unsafe stored config.
        assertFalse(_allowed(regionalPoolId, retailUser, OP_SWAP));
        assertFalse(_allowed(regionalPoolId, retailUser, OP_LP), "LP backdoor closed");
    }

    /// @dev Finding 2 on the V3 path.
    function test_Finding2_CountryAttestationDenies() public {
        _setRegional(true, false, ILexifiPolicy.AccessLevel.RETAIL, ILexifiPolicy.AccessLevel.RETAIL);

        assertFalse(_allowed(regionalPoolId, retailUser, OP_SWAP), "tier 1 has no country attn");
        assertTrue(_allowed(regionalPoolId, accreditedUser, OP_SWAP), "tier 2 does");
    }

    /// @dev Finding 3 on the V3 path.
    function test_Finding3_QuorumEnforced() public {
        address[] memory providers = new address[](2);
        providers[0] = address(provider);
        providers[1] = address(provider2);

        bytes32 ifam = institutionalV3.CONFIG_FAMILY();
        bytes memory idata = institutionalV3.encodeConfig(providers, 2, ILexifiPolicy.AccessLevel.ACCREDITED);
        vm.prank(owner);
        registry.setConfig(ifam, institutionalKey.toId(), idata);

        // Only provider1 clears them: 1 of 2, quorum is 2.
        assertFalse(_allowed(institutionalPoolId, accreditedUser, OP_SWAP), "quorum enforced");

        vm.prank(owner);
        provider2.setUser(accreditedUser, 2, true);
        assertTrue(_allowed(institutionalPoolId, accreditedUser, OP_SWAP), "quorum met");
    }

    /// @dev A stored quorum above the provider count must tighten to "all", not brick the pool.
    function test_Institutional_QuorumClampedToProviderCount() public {
        address[] memory providers = new address[](2);
        providers[0] = address(provider);
        providers[1] = address(provider2);

        bytes32 ifam = institutionalV3.CONFIG_FAMILY();
        bytes memory idata =
            institutionalV3.encodeConfig(providers, 99, ILexifiPolicy.AccessLevel.ACCREDITED);
        vm.startPrank(owner);
        registry.setConfig(ifam, institutionalKey.toId(), idata);
        provider2.setUser(accreditedUser, 2, true);
        vm.stopPrank();

        (InstitutionalPolicyV3.InstitutionalConfig memory cfg,) =
            institutionalV3.effectiveConfig(institutionalKey.toId());
        assertEq(cfg.minimumProviders, 2, "clamped to provider count");
        assertTrue(_allowed(institutionalPoolId, accreditedUser, OP_SWAP), "all providers pass");
    }

    /// @dev A stored zero quorum must not turn the policy into a no-op.
    function test_Institutional_ZeroQuorumRaisedToOne() public {
        address[] memory providers = new address[](2);
        providers[0] = address(provider);
        providers[1] = address(provider2);

        bytes32 ifam = institutionalV3.CONFIG_FAMILY();
        bytes memory idata = institutionalV3.encodeConfig(providers, 0, ILexifiPolicy.AccessLevel.ACCREDITED);
        vm.prank(owner);
        registry.setConfig(ifam, institutionalKey.toId(), idata);

        (InstitutionalPolicyV3.InstitutionalConfig memory cfg,) =
            institutionalV3.effectiveConfig(institutionalKey.toId());
        assertEq(cfg.minimumProviders, 1, "zero quorum raised to 1");
        assertFalse(_allowed(institutionalPoolId, retailUser, OP_SWAP), "unverified still denied");
    }

    /// @dev Empty provider list reads as unconfigured, which denies.
    function test_Institutional_EmptyProvidersDenied() public {
        address[] memory none = new address[](0);
        bytes32 ifam = institutionalV3.CONFIG_FAMILY();
        bytes memory idata = institutionalV3.encodeConfig(none, 1, ILexifiPolicy.AccessLevel.ACCREDITED);
        vm.prank(owner);
        registry.setConfig(ifam, institutionalKey.toId(), idata);
        assertFalse(_allowed(institutionalPoolId, accreditedUser, OP_SWAP));
    }
}
