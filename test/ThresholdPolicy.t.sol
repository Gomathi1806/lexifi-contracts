// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ThresholdPolicy} from "../src/policies/ThresholdPolicy.sol";
import {ILexifiPolicy} from "../src/interfaces/ILexifiPolicy.sol";
import {MockVerificationProvider} from "./mocks/MockVerificationProvider.sol";

contract ThresholdPolicyTest is Test {
    using PoolIdLibrary for PoolKey;

    ThresholdPolicy public policy;
    MockVerificationProvider public provider;

    address public admin = address(0xAD);
    address public retailUser = address(0x1);
    address public verifiedUser = address(0x2);
    address public enhancedUser = address(0x3);
    address public institutionalUser = address(0x4);
    address public unverifiedUser = address(0x5);

    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        provider = new MockVerificationProvider();
        policy = new ThresholdPolicy(address(provider), admin);

        // Set up user verification tiers
        provider.setUser(unverifiedUser, 0, false);
        provider.setUser(retailUser, 1, true);
        provider.setUser(verifiedUser, 1, true);
        provider.setUser(enhancedUser, 2, true);
        provider.setUser(institutionalUser, 3, true);

        // Create a pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x100)),
            currency1: Currency.wrap(address(0x200)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();

        // Configure pool: no KYC under 1000, enhanced above 10000
        vm.prank(admin);
        policy.setPoolConfig(
            poolId,
            1000e18,    // noKycLimit
            10000e18,   // enhancedLimit
            ILexifiPolicy.AccessLevel.RETAIL,   // lpMinimum
            ILexifiPolicy.AccessLevel.RETAIL    // swapMinimum
        );
    }

    // ═══════════════════════════════════════════
    //  POLICY METADATA
    // ═══════════════════════════════════════════

    function test_PolicyName() public view {
        assertEq(policy.policyName(), "Lexifi Threshold Policy");
    }

    function test_PolicyVersion() public view {
        assertEq(policy.policyVersion(), 1);
    }

    // ═══════════════════════════════════════════
    //  SMALL SWAP — NO KYC REQUIRED
    // ═══════════════════════════════════════════

    function test_SmallSwap_UnverifiedUser_Passes() public view {
        // Swap under noKycLimit: anyone can trade
        (ILexifiPolicy.AccessLevel level, string memory reason) =
            policy.checkAccess(poolId, unverifiedUser, 0, 500e18);

        // Should get INSTITUTIONAL level (auto-pass for small trades)
        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.INSTITUTIONAL));
        assertEq(bytes(reason).length, 0);
    }

    function test_SmallSwap_VerifiedUser_Passes() public view {
        (ILexifiPolicy.AccessLevel level, ) =
            policy.checkAccess(poolId, retailUser, 0, 999e18);

        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.INSTITUTIONAL));
    }

    // ═══════════════════════════════════════════
    //  MEDIUM SWAP — BASIC KYC REQUIRED
    // ═══════════════════════════════════════════

    function test_MediumSwap_VerifiedUser_Passes() public view {
        // Swap above noKycLimit but below enhancedLimit
        (ILexifiPolicy.AccessLevel level, string memory reason) =
            policy.checkAccess(poolId, retailUser, 0, 5000e18);

        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.RETAIL));
        assertEq(bytes(reason).length, 0);
    }

    function test_MediumSwap_UnverifiedUser_Denied() public view {
        // Unverified user tries medium swap
        (ILexifiPolicy.AccessLevel level, string memory reason) =
            policy.checkAccess(poolId, unverifiedUser, 0, 5000e18);

        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.DENIED));
        assertTrue(bytes(reason).length > 0);
    }

    // ═══════════════════════════════════════════
    //  LARGE SWAP — ENHANCED VERIFICATION REQUIRED
    // ═══════════════════════════════════════════

    function test_LargeSwap_EnhancedUser_Passes() public view {
        (ILexifiPolicy.AccessLevel level, string memory reason) =
            policy.checkAccess(poolId, enhancedUser, 0, 50000e18);

        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.ACCREDITED));
        assertEq(bytes(reason).length, 0);
    }

    function test_LargeSwap_RetailUser_Denied() public view {
        // Retail user tries large swap — needs ACCREDITED
        (ILexifiPolicy.AccessLevel level, string memory reason) =
            policy.checkAccess(poolId, retailUser, 0, 50000e18);

        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.RETAIL));
        assertTrue(bytes(reason).length > 0);
    }

    function test_LargeSwap_InstitutionalUser_Passes() public view {
        (ILexifiPolicy.AccessLevel level, ) =
            policy.checkAccess(poolId, institutionalUser, 0, 50000e18);

        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.INSTITUTIONAL));
    }

    // ═══════════════════════════════════════════
    //  LIQUIDITY — ALWAYS REQUIRES RETAIL MINIMUM
    // ═══════════════════════════════════════════

    function test_AddLiquidity_VerifiedUser_Passes() public view {
        (ILexifiPolicy.AccessLevel level, string memory reason) =
            policy.checkAccess(poolId, retailUser, 1, 100e18);

        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.RETAIL));
        assertEq(bytes(reason).length, 0);
    }

    function test_AddLiquidity_UnverifiedUser_Denied() public view {
        (ILexifiPolicy.AccessLevel level, string memory reason) =
            policy.checkAccess(poolId, unverifiedUser, 1, 100e18);

        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.DENIED));
        assertTrue(bytes(reason).length > 0);
    }

    // ═══════════════════════════════════════════
    //  MINIMUM LEVELS
    // ═══════════════════════════════════════════

    function test_MinimumLevel_Swap() public view {
        ILexifiPolicy.AccessLevel min = policy.minimumLevel(poolId, 0);
        assertEq(uint8(min), uint8(ILexifiPolicy.AccessLevel.RETAIL));
    }

    function test_MinimumLevel_AddLiquidity() public view {
        ILexifiPolicy.AccessLevel min = policy.minimumLevel(poolId, 1);
        assertEq(uint8(min), uint8(ILexifiPolicy.AccessLevel.RETAIL));
    }

    function test_MinimumLevel_RemoveLiquidity_NeverBlocked() public view {
        ILexifiPolicy.AccessLevel min = policy.minimumLevel(poolId, 2);
        assertEq(uint8(min), uint8(ILexifiPolicy.AccessLevel.DENIED)); // no minimum
    }

    // ═══════════════════════════════════════════
    //  UNCONFIGURED POOL — OPEN ACCESS
    // ═══════════════════════════════════════════

    function test_UnconfiguredPool_OpenAccess() public view {
        // Different pool that was never configured
        PoolKey memory otherKey = PoolKey({
            currency0: Currency.wrap(address(0x300)),
            currency1: Currency.wrap(address(0x400)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PoolId otherPoolId = otherKey.toId();

        (ILexifiPolicy.AccessLevel level, ) =
            policy.checkAccess(otherPoolId, unverifiedUser, 0, 999999e18);

        // Unconfigured = open access
        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.INSTITUTIONAL));
    }

    // ═══════════════════════════════════════════
    //  MANUAL OVERRIDE
    // ═══════════════════════════════════════════

    function test_Override_GrantsTier() public {
        // Admin grants override to unverified user
        vm.prank(admin);
        policy.setOverride(unverifiedUser, ILexifiPolicy.AccessLevel.ACCREDITED);

        // Now unverified user has ACCREDITED access
        (ILexifiPolicy.AccessLevel level, ) =
            policy.checkAccess(poolId, unverifiedUser, 0, 50000e18);

        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.ACCREDITED));
    }

    function test_Override_OnlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(ThresholdPolicy.Unauthorized.selector);
        policy.setOverride(unverifiedUser, ILexifiPolicy.AccessLevel.RETAIL);
    }

    // ═══════════════════════════════════════════
    //  POOL CONFIG — ACCESS CONTROL
    // ═══════════════════════════════════════════

    function test_SetPoolConfig_OnlyAdmin() public {
        // Someone else tries to reconfigure
        vm.prank(address(0xBAD));
        vm.expectRevert(ThresholdPolicy.Unauthorized.selector);
        policy.setPoolConfig(poolId, 0, 0, ILexifiPolicy.AccessLevel.DENIED, ILexifiPolicy.AccessLevel.DENIED);
    }

    function test_SetPoolConfig_AdminCanUpdate() public {
        // Admin updates config
        vm.prank(admin);
        policy.setPoolConfig(
            poolId,
            500e18,
            5000e18,
            ILexifiPolicy.AccessLevel.ACCREDITED,
            ILexifiPolicy.AccessLevel.ACCREDITED
        );

        // Now swap minimum is ACCREDITED
        ILexifiPolicy.AccessLevel min = policy.minimumLevel(poolId, 0);
        assertEq(uint8(min), uint8(ILexifiPolicy.AccessLevel.ACCREDITED));
    }

    function test_TransferPoolAdmin() public {
        address newAdmin = address(0xEEEE);

        vm.prank(admin);
        policy.transferPoolAdmin(poolId, newAdmin);

        // Old admin can no longer configure
        vm.prank(admin);
        vm.expectRevert(ThresholdPolicy.Unauthorized.selector);
        policy.setPoolConfig(poolId, 0, 0, ILexifiPolicy.AccessLevel.DENIED, ILexifiPolicy.AccessLevel.DENIED);

        // New admin can
        vm.prank(newAdmin);
        policy.setPoolConfig(poolId, 0, 0, ILexifiPolicy.AccessLevel.DENIED, ILexifiPolicy.AccessLevel.DENIED);
    }
}
