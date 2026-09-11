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
import {ThresholdPolicy} from "../src/policies/ThresholdPolicy.sol";
import {InstitutionalPolicy} from "../src/policies/InstitutionalPolicy.sol";
import {SelfAttestationProvider} from "../src/policies/SelfAttestationProvider.sol";
import {MockVerificationProvider} from "./mocks/MockVerificationProvider.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {LexifiComplianceAdapter} from "../src/integrations/LexifiComplianceAdapter.sol";
import {MockAqua0V4Adapter} from "./mocks/MockAqua0V4Adapter.sol";
import {ILexifiCompliance} from "../src/integrations/ILexifiCompliance.sol";

/// @title Aqua0 Integration Tests
/// @notice Proves the full Lexifi ↔ Aqua0 compliance flow end-to-end.
/// @dev Simulates Aqua0's V4Adapter calling Lexifi's compliance check
///      during beforeSwap, demonstrating both pass and deny scenarios.
contract Aqua0IntegrationTest is Test {
    using PoolIdLibrary for PoolKey;

    MockPoolManager poolManager;
    LexifiHook hook;
    LexifiComplianceAdapter adapter;
    MockAqua0V4Adapter aqua0;

    // Policies
    ThresholdPolicy thresholdPolicy;
    InstitutionalPolicy institutionalPolicy;

    // Verification providers
    MockVerificationProvider coinbaseProvider;
    SelfAttestationProvider selfAttestProvider;

    // Actors
    address owner = address(0xCAFE);
    address verifiedTrader = address(0x1111);
    address unverifiedTrader = address(0x2222);
    address institutionalTrader = address(0x3333);

    // Pool
    PoolKey poolKey;
    PoolId poolId;
    bytes32 poolIdBytes;

    function setUp() public {
        vm.startPrank(owner);

        // Deploy core
        poolManager = new MockPoolManager();
        hook = new LexifiHook(IPoolManager(address(poolManager)), owner);

        // Deploy verification providers
        coinbaseProvider = new MockVerificationProvider();
        selfAttestProvider = new SelfAttestationProvider(owner, "Lexifi Operator KYC");

        // Deploy policies
        thresholdPolicy = new ThresholdPolicy(address(coinbaseProvider), owner);
        institutionalPolicy = new InstitutionalPolicy(owner);

        // Deploy the compliance adapter (bridges Aqua0 → Lexifi)
        adapter = new LexifiComplianceAdapter(address(hook));

        // Deploy mock Aqua0 V4Adapter with compliance
        aqua0 = new MockAqua0V4Adapter(address(adapter));

        // Set up pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x4200000000000000000000000000000000000006)), // WETH
            currency1: Currency.wrap(address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)), // USDC
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        poolIdBytes = PoolId.unwrap(poolId);

        // Register ThresholdPolicy on the pool
        hook.setPoolPolicy(poolKey, address(thresholdPolicy));

        // Configure: no-KYC limit = 100 tokens, swap requires RETAIL
        thresholdPolicy.setPoolConfig(
            poolId, 100e18, 10000e18,
            ILexifiPolicy.AccessLevel.RETAIL,
            ILexifiPolicy.AccessLevel.RETAIL
        );

        // Set up verified users
        coinbaseProvider.setUser(verifiedTrader, 1, true); // Retail tier
        coinbaseProvider.setUser(institutionalTrader, 3, true); // Institutional tier
        // unverifiedTrader has no verification

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════
    //  CORE FLOW: Aqua0 swap with compliance
    // ═══════════════════════════════════════════

    function test_Aqua0Swap_VerifiedTrader_Passes() public {
        // Verified trader swaps above no-KYC limit — should pass
        aqua0.simulateBeforeSwap(
            poolIdBytes,
            verifiedTrader,
            500e18,
            hex"01" // mock JIT auth
        );
    }

    function test_Aqua0Swap_UnverifiedTrader_BelowLimit_Passes() public {
        // Unverified trader swaps below no-KYC limit — should pass
        aqua0.simulateBeforeSwap(
            poolIdBytes,
            unverifiedTrader,
            50e18,
            hex"01"
        );
    }

    function test_Aqua0Swap_UnverifiedTrader_AboveLimit_Denied() public {
        // Unverified trader swaps above no-KYC limit — should be denied
        vm.expectRevert(
            abi.encodeWithSelector(
                MockAqua0V4Adapter.ComplianceDenied.selector,
                unverifiedTrader,
                "Swap requires basic verification"
            )
        );
        aqua0.simulateBeforeSwap(
            poolIdBytes,
            unverifiedTrader,
            500e18,
            hex"01"
        );
    }

    function test_Aqua0Swap_InvalidJITAuth_Reverts() public {
        // Missing JIT auth reverts before compliance check
        vm.expectRevert(MockAqua0V4Adapter.InvalidJITAuth.selector);
        aqua0.simulateBeforeSwap(
            poolIdBytes,
            verifiedTrader,
            500e18,
            hex""
        );
    }

    // ═══════════════════════════════════════════
    //  COMPLIANCE DISABLED: permissionless mode
    // ═══════════════════════════════════════════

    function test_Aqua0Swap_ComplianceDisabled_AnyoneSwaps() public {
        // Disable compliance — Aqua0 can toggle per-pool
        aqua0.setComplianceAdapter(address(0));

        // Unverified trader swaps any amount — passes without check
        aqua0.simulateBeforeSwap(
            poolIdBytes,
            unverifiedTrader,
            1000000e18,
            hex"01"
        );
    }

    // ═══════════════════════════════════════════
    //  MULTI-PROVIDER: InstitutionalPolicy + SelfAttestation
    // ═══════════════════════════════════════════

    function test_Aqua0Swap_InstitutionalPolicy_DualProvider() public {
        vm.startPrank(owner);

        // Reconfigure pool with InstitutionalPolicy (N-of-M verification)
        hook.setPoolPolicy(poolKey, address(institutionalPolicy));

        // Set up 2-of-2 provider requirement
        address[] memory providers = new address[](2);
        providers[0] = address(coinbaseProvider);
        providers[1] = address(selfAttestProvider);
        institutionalPolicy.setInstitutionalConfig(poolId, providers, 2, ILexifiPolicy.AccessLevel.ACCREDITED);

        // Attest the institutional trader via SelfAttestationProvider
        selfAttestProvider.attest(institutionalTrader, 3, 0); // tier 3, no expiry

        vm.stopPrank();

        // Institutional trader has BOTH providers — should pass
        aqua0.simulateBeforeSwap(
            poolIdBytes,
            institutionalTrader,
            1000000e18,
            hex"01"
        );
    }

    function test_Aqua0Swap_InstitutionalPolicy_MissingProvider_Denied() public {
        vm.startPrank(owner);

        hook.setPoolPolicy(poolKey, address(institutionalPolicy));

        address[] memory providers = new address[](2);
        providers[0] = address(coinbaseProvider);
        providers[1] = address(selfAttestProvider);
        institutionalPolicy.setInstitutionalConfig(poolId, providers, 2, ILexifiPolicy.AccessLevel.ACCREDITED);

        // verifiedTrader only has Coinbase EAS, NOT SelfAttestation
        vm.stopPrank();

        vm.expectRevert();
        aqua0.simulateBeforeSwap(
            poolIdBytes,
            verifiedTrader,
            1000000e18,
            hex"01"
        );
    }

    // ═══════════════════════════════════════════
    //  VAULT LP GATING
    // ═══════════════════════════════════════════

    function test_Aqua0VaultDeposit_VerifiedLP_Passes() public {
        aqua0.simulateVaultDeposit(poolIdBytes, verifiedTrader, 10000e18);
    }

    function test_Aqua0VaultDeposit_UnverifiedLP_Denied() public {
        // Unverified LP tries to deposit above threshold — denied
        vm.expectRevert();
        aqua0.simulateVaultDeposit(poolIdBytes, unverifiedTrader, 10000e18);
    }

    // ═══════════════════════════════════════════
    //  ADAPTER VIEW FUNCTIONS
    // ═══════════════════════════════════════════

    function test_Adapter_HasPolicy() public view {
        assertTrue(adapter.hasPolicy(poolIdBytes));
    }

    function test_Adapter_NoPolicyPool() public view {
        bytes32 randomPool = keccak256("random");
        assertFalse(adapter.hasPolicy(randomPool));

        // Pool without policy returns allowed=true
        (bool allowed, , , ) = adapter.checkCompliance(randomPool, unverifiedTrader, 0, 1e18);
        assertTrue(allowed);
    }

    function test_Adapter_CheckCompliance_ReturnsFullDetails() public view {
        (bool allowed, uint8 userTier, uint8 requiredTier, string memory reason) =
            adapter.checkCompliance(poolIdBytes, verifiedTrader, 0, 500e18);

        assertTrue(allowed);
        assertEq(userTier, 1); // RETAIL
        assertEq(requiredTier, 1); // RETAIL required
        assertEq(bytes(reason).length, 0);
    }

    function test_Adapter_CheckCompliance_DeniedDetails() public view {
        (bool allowed, uint8 userTier, uint8 requiredTier, string memory reason) =
            adapter.checkCompliance(poolIdBytes, unverifiedTrader, 0, 500e18);

        assertFalse(allowed);
        assertEq(userTier, 0); // DENIED
        assertEq(requiredTier, 1); // RETAIL required
        assertTrue(bytes(reason).length > 0);
    }
}
