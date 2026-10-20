// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {LexifiHook} from "../src/LexifiHook.sol";
import {LexifiHookV3} from "../src/LexifiHookV3.sol";
import {LexifiHookV4} from "../src/LexifiHookV4.sol";
import {LexifiPolicyConfig} from "../src/LexifiPolicyConfig.sol";
import {LexifiPolicyConfigV2, IPoolAdminSource} from "../src/LexifiPolicyConfigV2.sol";
import {ILexifiPolicy} from "../src/interfaces/ILexifiPolicy.sol";
import {RegionalPolicyV3} from "../src/policies/RegionalPolicyV3.sol";
import {RegionalPolicyV4} from "../src/policies/RegionalPolicyV4.sol";
import {InstitutionalPolicyV3} from "../src/policies/InstitutionalPolicyV3.sol";
import {InstitutionalPolicyV4} from "../src/policies/InstitutionalPolicyV4.sol";
import {ThresholdPolicy} from "../src/policies/ThresholdPolicy.sol";
import {ThresholdPolicyV3} from "../src/policies/ThresholdPolicyV3.sol";
import {ThresholdPolicyV4} from "../src/policies/ThresholdPolicyV4.sol";
import {LexifiComplianceAdapter} from "../src/integrations/LexifiComplianceAdapter.sol";
import {LexifiSwapAmount} from "../src/libraries/LexifiSwapAmount.sol";
import {MockVerificationProvider} from "./mocks/MockVerificationProvider.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MockAqua0V4Adapter} from "./mocks/MockAqua0V4Adapter.sol";

/// @notice Attacker policy from the Olympix finding 4 PoC: admits everyone.
contract AdmitAllPolicy is ILexifiPolicy {
    function checkAccess(PoolId, address, uint8, uint256)
        external
        pure
        returns (AccessLevel, string memory)
    {
        return (AccessLevel.INSTITUTIONAL, "");
    }

    function minimumLevel(PoolId, uint8) external pure returns (AccessLevel) {
        return AccessLevel.DENIED;
    }

    function policyName() external pure returns (string memory) {
        return "Totally Legit Policy";
    }

    function policyVersion() external pure returns (uint256) {
        return 1;
    }
}

/// @title Olympix BugPoCer scan (2026-10-19) — regression tests for all four Medium issues
/// @dev Each issue has an `Old_` test that reproduces the PoC on the code it was found in
///      (asserting the bypass exists, so the PoC is known to be real) and a `New_` test that
///      runs the same attack against the fixed contracts and asserts the PoC's harm assertions
///      now hold. Verdicts are asserted through `checkAccess().level >= minimumLevel(op)`
///      (`_passes`) and through the hook's real `beforeSwap` / `beforeAddLiquidity`, never
///      through `reason`.
contract OlympixRegressionTest is Test {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint8 constant OP_SWAP = 0;
    uint8 constant OP_LP = 1;
    uint8 constant OP_REMOVE = 2;

    ILexifiPolicy.AccessLevel constant DENIED = ILexifiPolicy.AccessLevel.DENIED;
    ILexifiPolicy.AccessLevel constant RETAIL = ILexifiPolicy.AccessLevel.RETAIL;
    ILexifiPolicy.AccessLevel constant ACCREDITED = ILexifiPolicy.AccessLevel.ACCREDITED;

    // currency0 = 18-decimal TOKEN, currency1 = 6-decimal USDC (Base address), as in the PoC.
    address constant TOKEN = address(0x1000000000000000000000000000000000000001);
    address constant USDC = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    PoolManager manager;
    MockVerificationProvider provider;
    MockVerificationProvider providerB;

    address lexifiSafe = makeAddr("lexifiSafe");
    address issuer = makeAddr("issuer");
    address attacker = makeAddr("attacker"); // no attestation anywhere
    address tier0 = makeAddr("tier0"); // verified, tier 0
    address retail = makeAddr("retail"); // verified, tier 1
    address accredited = makeAddr("accredited"); // verified, tier 2
    address dualVerified = makeAddr("dualVerified"); // tier 1 on both providers
    address halfVerified = makeAddr("halfVerified"); // tier 1 on provider A only

    function setUp() public {
        manager = new PoolManager(address(this));
        provider = new MockVerificationProvider();
        providerB = new MockVerificationProvider();

        provider.setUser(tier0, 0, true);
        provider.setUser(retail, 1, true);
        provider.setUser(accredited, 2, true);
        provider.setUser(dualVerified, 1, true);
        providerB.setUser(dualVerified, 1, true);
        provider.setUser(halfVerified, 1, true);
    }

    // ═══════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════

    function _hookAddr(uint16 salt) internal pure returns (address) {
        return address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG
            ) | (uint160(salt) << 144)
        );
    }

    function _deployV3() internal returns (LexifiHookV3 hook) {
        address a = _hookAddr(0x3333);
        deployCodeTo("LexifiHookV3.sol:LexifiHookV3", abi.encode(IPoolManager(address(manager)), lexifiSafe), a);
        hook = LexifiHookV3(a);
    }

    function _deployV4() internal returns (LexifiHookV4 hook) {
        address a = _hookAddr(0x4444);
        deployCodeTo("LexifiHookV4.sol:LexifiHookV4", abi.encode(IPoolManager(address(manager)), lexifiSafe), a);
        hook = LexifiHookV4(a);
    }

    function _key(address hook) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(TOKEN),
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
    }

    /// @dev The enforcement comparison, exactly as every hook and the adapter compute it.
    function _passes(ILexifiPolicy policy, PoolId poolId, address user, uint8 op, uint256 amount)
        internal
        view
        returns (bool)
    {
        (ILexifiPolicy.AccessLevel level,) = policy.checkAccess(poolId, user, op, amount);
        return uint8(level) >= uint8(policy.minimumLevel(poolId, op));
    }

    function _hookSwap(address hook, PoolKey memory key, address user, bool zeroForOne, int256 amountSpecified)
        internal
        returns (bool ok)
    {
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: 0
        });
        vm.prank(address(manager));
        (ok,) = hook.call(abi.encodeCall(IHooks.beforeSwap, (user, key, p, "")));
    }

    function _hookAddLiquidity(address hook, PoolKey memory key, address user) internal returns (bool ok) {
        IPoolManager.ModifyLiquidityParams memory p = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: 1_000_000e18,
            salt: bytes32(0)
        });
        vm.prank(address(manager));
        (ok,) = hook.call(abi.encodeCall(IHooks.beforeAddLiquidity, (user, key, p, "")));
    }

    // ═══════════════════════════════════════════
    //  ISSUE 1 — DENIED minimum turns denials into passes
    // ═══════════════════════════════════════════

    struct RegionalStack {
        address hook;
        PoolKey key;
        PoolId poolId;
        ILexifiPolicy policy;
    }

    function _regionalV3(bool requireCountry, ILexifiPolicy.AccessLevel minSwap, ILexifiPolicy.AccessLevel minLp)
        internal
        returns (RegionalStack memory s)
    {
        LexifiHookV3 hook = _deployV3();
        LexifiPolicyConfigV2 registry = new LexifiPolicyConfigV2(IPoolAdminSource(address(hook)));
        RegionalPolicyV3 policy = new RegionalPolicyV3(address(provider), address(registry), lexifiSafe);
        s = RegionalStack(address(hook), _key(address(hook)), PoolId.wrap(0), ILexifiPolicy(address(policy)));
        s.poolId = s.key.toId();
        vm.startPrank(issuer);
        hook.createPool(s.key, SQRT_PRICE_1_1, address(policy));
        registry.setConfig(
            policy.CONFIG_FAMILY(), s.poolId, policy.encodeConfig(requireCountry, false, minSwap, minLp)
        );
        vm.stopPrank();
    }

    function _regionalV4(bool requireCountry, ILexifiPolicy.AccessLevel minSwap, ILexifiPolicy.AccessLevel minLp)
        internal
        returns (RegionalStack memory s)
    {
        LexifiHookV4 hook = _deployV4();
        LexifiPolicyConfigV2 registry = new LexifiPolicyConfigV2(IPoolAdminSource(address(hook)));
        RegionalPolicyV4 policy = new RegionalPolicyV4(address(provider), address(registry));
        s = RegionalStack(address(hook), _key(address(hook)), PoolId.wrap(0), ILexifiPolicy(address(policy)));
        s.poolId = s.key.toId();
        vm.startPrank(issuer);
        hook.createPool(s.key, SQRT_PRICE_1_1, address(policy));
        registry.setConfig(
            policy.CONFIG_FAMILY(), s.poolId, policy.encodeConfig(requireCountry, false, minSwap, minLp)
        );
        vm.stopPrank();
    }

    /// Old: RegionalPolicyV3 with minimums DENIED admits a wallet with no verification.
    function test_Issue1_Old_RegionalV3_DeniedMinimum_AdmitsUnverified() public {
        RegionalStack memory s = _regionalV3(false, DENIED, DENIED);
        assertTrue(_passes(s.policy, s.poolId, attacker, OP_SWAP, 1e18), "bug: unverified passes swap");
        assertTrue(_passes(s.policy, s.poolId, attacker, OP_LP, 1e18), "bug: unverified passes LP");
        assertTrue(_hookSwap(s.hook, s.key, attacker, true, -1e18), "bug: hook lets unverified swap");
        assertTrue(_hookAddLiquidity(s.hook, s.key, attacker), "bug: hook lets unverified LP");
    }

    /// Old: the country flag gates nothing when the minimum is DENIED.
    function test_Issue1_Old_RegionalV3_CountryFlagNoOpWhenMinimumDenied() public {
        RegionalStack memory s = _regionalV3(true, DENIED, DENIED);
        assertTrue(_passes(s.policy, s.poolId, retail, OP_SWAP, 1e18), "bug: tier 1 passes country gate");
    }

    function test_Issue1_New_RegionalV4_DeniedMinimum_DeniesUnverified() public {
        RegionalStack memory s = _regionalV4(false, DENIED, DENIED);
        assertFalse(_passes(s.policy, s.poolId, attacker, OP_SWAP, 1e18), "unverified swap denied");
        assertFalse(_passes(s.policy, s.poolId, attacker, OP_LP, 1e18), "unverified LP denied");
        assertFalse(_hookSwap(s.hook, s.key, attacker, true, -1e18), "hook denies unverified swap");
        assertFalse(_hookAddLiquidity(s.hook, s.key, attacker), "hook denies unverified LP");

        // A DENIED minimum still means "any verified user": tier 0 and tier 1 pass.
        assertTrue(_passes(s.policy, s.poolId, tier0, OP_SWAP, 1e18), "verified tier 0 swaps");
        assertTrue(_passes(s.policy, s.poolId, tier0, OP_LP, 1e18), "verified tier 0 LPs");
        assertTrue(_hookSwap(s.hook, s.key, retail, true, -1e18), "retail swaps through hook");
        assertEq(uint8(s.policy.minimumLevel(s.poolId, OP_SWAP)), uint8(RETAIL), "floor");
        assertEq(uint8(s.policy.minimumLevel(s.poolId, OP_REMOVE)), uint8(DENIED), "exit never gated");
    }

    function test_Issue1_New_RegionalV4_CountryFlagHoldsWhenMinimumDenied() public {
        RegionalStack memory s = _regionalV4(true, DENIED, DENIED);
        assertFalse(_passes(s.policy, s.poolId, retail, OP_SWAP, 1e18), "tier 1 denied by country flag");
        assertFalse(_hookSwap(s.hook, s.key, retail, true, -1e18), "hook denies tier 1");
        assertTrue(_passes(s.policy, s.poolId, accredited, OP_SWAP, 1e18), "tier 2 passes");
    }

    /// A stored RETAIL minimum must not be loosened by the lift: tier 0 stays out.
    function test_Issue1_New_RegionalV4_RetailMinimumUnchanged() public {
        RegionalStack memory s = _regionalV4(false, RETAIL, ACCREDITED);
        assertFalse(_passes(s.policy, s.poolId, tier0, OP_SWAP, 1e18), "tier 0 below RETAIL");
        assertTrue(_passes(s.policy, s.poolId, retail, OP_SWAP, 1e18), "retail swaps");
        assertFalse(_passes(s.policy, s.poolId, retail, OP_LP, 1e18), "retail cannot LP");
        assertTrue(_passes(s.policy, s.poolId, accredited, OP_LP, 1e18), "accredited LPs");
    }

    function _institutionalProviders() internal view returns (address[] memory providers) {
        providers = new address[](2);
        providers[0] = address(provider);
        providers[1] = address(providerB);
    }

    /// Old (PoC b, on the V3 successor): a 2-of-2 quorum with minTier DENIED admits anyone.
    function test_Issue1_Old_InstitutionalV3_DeniedMinTier_QuorumGatesNobody() public {
        LexifiHookV3 hook = _deployV3();
        LexifiPolicyConfigV2 registry = new LexifiPolicyConfigV2(IPoolAdminSource(address(hook)));
        InstitutionalPolicyV3 policy = new InstitutionalPolicyV3(address(registry), lexifiSafe);
        PoolKey memory key = _key(address(hook));
        PoolId poolId = key.toId();
        vm.startPrank(issuer);
        hook.createPool(key, SQRT_PRICE_1_1, address(policy));
        registry.setConfig(policy.CONFIG_FAMILY(), poolId, policy.encodeConfig(_institutionalProviders(), 2, DENIED));
        vm.stopPrank();

        assertTrue(_passes(ILexifiPolicy(address(policy)), poolId, attacker, OP_SWAP, 1e18), "bug: quorum no-op");
        assertTrue(_hookSwap(address(hook), key, attacker, true, -1_000_000e18), "bug: hook admits");
        assertTrue(_hookAddLiquidity(address(hook), key, attacker), "bug: hook admits LP");
    }

    function test_Issue1_New_InstitutionalV4_DeniedMinTier_QuorumHolds() public {
        LexifiHookV4 hook = _deployV4();
        LexifiPolicyConfigV2 registry = new LexifiPolicyConfigV2(IPoolAdminSource(address(hook)));
        InstitutionalPolicyV4 policy = new InstitutionalPolicyV4(address(registry));
        PoolKey memory key = _key(address(hook));
        PoolId poolId = key.toId();
        vm.startPrank(issuer);
        hook.createPool(key, SQRT_PRICE_1_1, address(policy));
        registry.setConfig(policy.CONFIG_FAMILY(), poolId, policy.encodeConfig(_institutionalProviders(), 2, DENIED));
        vm.stopPrank();
        ILexifiPolicy p = ILexifiPolicy(address(policy));

        // PoC harm assertions.
        assertFalse(_hookSwap(address(hook), key, attacker, true, -1_000_000e18), "unverified swap denied");
        assertFalse(_hookAddLiquidity(address(hook), key, attacker), "unverified LP denied");
        assertFalse(_passes(p, poolId, attacker, OP_SWAP, 1e18), "comparison denies");
        // 1 of 2 is short of quorum.
        assertFalse(_passes(p, poolId, halfVerified, OP_SWAP, 1e18), "1-of-2 denied");
        // Verified by both: passes.
        assertTrue(_passes(p, poolId, dualVerified, OP_SWAP, 1e18), "2-of-2 passes");
        assertTrue(_hookSwap(address(hook), key, dualVerified, true, -1e18), "2-of-2 swaps through hook");
        assertEq(uint8(p.minimumLevel(poolId, OP_REMOVE)), uint8(DENIED), "exit never gated");
    }

    /// Old (PoC a, live v1 ThresholdPolicy): large-trade check is a no-op with swapMinimum DENIED.
    function test_Issue1_Old_ThresholdV1_LargeTradeNoOp() public {
        MockPoolManager mockPM = new MockPoolManager();
        LexifiHook hook = new LexifiHook(IPoolManager(address(mockPM)), lexifiSafe);
        ThresholdPolicy policy = new ThresholdPolicy(address(provider), issuer);
        PoolKey memory key = _key(address(hook));
        PoolId poolId = key.toId();
        vm.startPrank(issuer);
        hook.setPoolPolicy(key, address(policy));
        policy.setPoolConfig(poolId, 1_000e18, 10_000e18, DENIED, DENIED);
        vm.stopPrank();
        assertTrue(_passes(ILexifiPolicy(address(policy)), poolId, attacker, OP_SWAP, 50_000e18), "bug");
        assertTrue(_passes(ILexifiPolicy(address(policy)), poolId, retail, OP_SWAP, 50_000e18), "bug");
    }

    function test_Issue1_New_ThresholdV4_LargeTradeHolds() public {
        (LexifiHookV4 hook, ThresholdPolicyV4 policy, PoolKey memory key, PoolId poolId) =
            _thresholdV4(1_000e18, 10_000e18, 1_000e6, 10_000e6, DENIED, DENIED);
        ILexifiPolicy p = ILexifiPolicy(address(policy));
        uint256 large = LexifiSwapAmount.encode(true, -int256(50_000e18));
        assertFalse(_passes(p, poolId, attacker, OP_SWAP, large), "unverified large trade denied");
        assertFalse(_passes(p, poolId, retail, OP_SWAP, large), "retail large trade denied");
        assertTrue(_passes(p, poolId, accredited, OP_SWAP, large), "accredited large trade passes");
        assertTrue(_hookSwap(address(hook), key, attacker, true, -int256(10_000e18)), "middle band open by config");
        assertFalse(_hookSwap(address(hook), key, attacker, true, -int256(50_000e18)), "hook denies large");
    }

    // ═══════════════════════════════════════════
    //  ISSUE 2 — first-writer config admin not bound to hook pool admin
    // ═══════════════════════════════════════════

    /// Old: on LexifiPolicyConfig (v1, live on Base and Robinhood), a stranger claims the slot,
    /// opens the pool and locks the issuer out.
    function test_Issue2_Old_RegistryV1_StrangerClaimsSlot() public {
        LexifiHookV3 hook = _deployV3();
        LexifiPolicyConfig registry = new LexifiPolicyConfig();
        RegionalPolicyV3 policy = new RegionalPolicyV3(address(provider), address(registry), lexifiSafe);
        PoolKey memory key = _key(address(hook));
        PoolId poolId = key.toId();
        bytes32 family = policy.CONFIG_FAMILY();

        vm.prank(issuer);
        hook.createPool(key, SQRT_PRICE_1_1, address(policy));

        vm.prank(attacker);
        registry.setConfig(family, poolId, policy.encodeConfig(false, false, DENIED, DENIED));

        bytes memory issuerCfg = policy.encodeConfig(true, true, RETAIL, RETAIL);
        vm.prank(issuer);
        vm.expectRevert(LexifiPolicyConfig.Unauthorized.selector);
        registry.setConfig(family, poolId, issuerCfg);

        assertTrue(_hookSwap(address(hook), key, attacker, true, -1e18), "bug: squatted config admits");
    }

    function test_Issue2_New_RegistryV2_StrangerCannotWrite() public {
        LexifiHookV4 hook = _deployV4();
        LexifiPolicyConfigV2 registry = new LexifiPolicyConfigV2(IPoolAdminSource(address(hook)));
        RegionalPolicyV4 policy = new RegionalPolicyV4(address(provider), address(registry));
        PoolKey memory key = _key(address(hook));
        PoolId poolId = key.toId();
        bytes32 family = policy.CONFIG_FAMILY();
        bytes memory open = policy.encodeConfig(false, false, DENIED, DENIED);

        // Before the pool exists: nobody can claim it.
        vm.prank(attacker);
        vm.expectRevert(LexifiPolicyConfigV2.Unauthorized.selector);
        registry.setConfig(family, poolId, open);

        vm.prank(issuer);
        hook.createPool(key, SQRT_PRICE_1_1, address(policy));

        // After: still only the hook's pool admin.
        vm.prank(attacker);
        vm.expectRevert(LexifiPolicyConfigV2.Unauthorized.selector);
        registry.setConfig(family, poolId, open);

        bytes memory issuerCfg = policy.encodeConfig(true, true, RETAIL, RETAIL);
        vm.prank(issuer);
        registry.setConfig(family, poolId, issuerCfg);

        assertFalse(_hookSwap(address(hook), key, attacker, true, -1e18), "unverified denied");
        assertFalse(_hookSwap(address(hook), key, retail, true, -1e18), "country flag holds");
        assertTrue(_hookSwap(address(hook), key, accredited, true, -1e18), "tier 2 passes");
    }

    // ═══════════════════════════════════════════
    //  ISSUE 3 — unit mismatch threshold bypass
    // ═══════════════════════════════════════════

    uint256 constant NO_KYC_TOKEN = 1e14; // guide default, "0.0001 ETH"
    uint256 constant ENHANCED_TOKEN = 1e18;
    uint256 constant NO_KYC_USDC = 1e5; // 0.10 USDC
    uint256 constant ENHANCED_USDC = 1_000e6; // 1,000 USDC
    uint256 constant HUGE_USDC = 1e14; // 100,000,000 USDC

    function _thresholdV4(
        uint256 noKyc0,
        uint256 enhanced0,
        uint256 noKyc1,
        uint256 enhanced1,
        ILexifiPolicy.AccessLevel lpMin,
        ILexifiPolicy.AccessLevel swapMin
    ) internal returns (LexifiHookV4 hook, ThresholdPolicyV4 policy, PoolKey memory key, PoolId poolId) {
        hook = _deployV4();
        LexifiPolicyConfigV2 registry = new LexifiPolicyConfigV2(IPoolAdminSource(address(hook)));
        policy = new ThresholdPolicyV4(address(provider), address(registry));
        key = _key(address(hook));
        poolId = key.toId();
        vm.startPrank(issuer);
        hook.createPool(key, SQRT_PRICE_1_1, address(policy));
        registry.setConfig(
            policy.CONFIG_FAMILY(),
            poolId,
            policy.encodeConfig(noKyc0, enhanced0, noKyc1, enhanced1, lpMin, swapMin)
        );
        vm.stopPrank();
    }

    /// Old: HookV3 + ThresholdPolicyV3 (the newest code before this fix). An unverified wallet
    /// swaps 100M USDC by stating the amount on the USDC side.
    function test_Issue3_Old_HookV3_ThresholdV3_UsdcSideBypass() public {
        LexifiHookV3 hook = _deployV3();
        LexifiPolicyConfigV2 registry = new LexifiPolicyConfigV2(IPoolAdminSource(address(hook)));
        ThresholdPolicyV3 policy = new ThresholdPolicyV3(address(provider), address(registry));
        PoolKey memory key = _key(address(hook));
        vm.startPrank(issuer);
        hook.createPool(key, SQRT_PRICE_1_1, address(policy));
        registry.setConfig(
            policy.CONFIG_FAMILY(), key.toId(), policy.encodeConfig(NO_KYC_TOKEN, ENHANCED_TOKEN, DENIED, RETAIL)
        );
        vm.stopPrank();

        assertFalse(_hookSwap(address(hook), key, attacker, true, -1e16), "sanity: 0.01 TOKEN is gated");
        assertTrue(_hookSwap(address(hook), key, attacker, false, -int256(HUGE_USDC)), "bug: exact-in USDC");
        assertTrue(_hookSwap(address(hook), key, attacker, true, int256(HUGE_USDC)), "bug: exact-out USDC");
    }

    /// Old: the live v1 stack (LexifiHook + ThresholdPolicy), the PoC as written.
    function test_Issue3_Old_HookV1_ThresholdV1_UsdcSideBypass() public {
        MockPoolManager mockPM = new MockPoolManager();
        LexifiHook hook = new LexifiHook(IPoolManager(address(mockPM)), lexifiSafe);
        ThresholdPolicy policy = new ThresholdPolicy(address(provider), lexifiSafe);
        PoolKey memory key = _key(address(hook));
        vm.startPrank(issuer);
        hook.setPoolPolicy(key, address(policy));
        policy.setPoolConfig(key.toId(), NO_KYC_TOKEN, ENHANCED_TOKEN, DENIED, RETAIL);
        vm.stopPrank();

        (bool allowed,,,) = hook.checkUserCompliance(key, attacker, OP_SWAP, HUGE_USDC);
        assertTrue(allowed, "bug: 100M USDC reads as a small trade");
    }

    function test_Issue3_New_HookV4_ThresholdV4_UsdcSideDenied() public {
        (LexifiHookV4 hook,, PoolKey memory key,) =
            _thresholdV4(NO_KYC_TOKEN, ENHANCED_TOKEN, NO_KYC_USDC, ENHANCED_USDC, DENIED, RETAIL);
        address h = address(hook);

        // PoC harm assertions.
        assertFalse(_hookSwap(h, key, attacker, true, -1e16), "0.01 TOKEN gated");
        assertFalse(_hookSwap(h, key, attacker, false, -int256(HUGE_USDC)), "exact-in 100M USDC denied");
        assertFalse(_hookSwap(h, key, attacker, true, int256(HUGE_USDC)), "exact-out 100M USDC denied");
        (bool allowedView,,,) = hook.checkSwapCompliance(key, attacker, false, -int256(HUGE_USDC));
        assertFalse(allowedView, "preview denies");

        // Small trades are measured in their own token.
        assertTrue(_hookSwap(h, key, attacker, true, -int256(NO_KYC_TOKEN)), "small TOKEN exact-in open");
        assertTrue(_hookSwap(h, key, attacker, false, int256(NO_KYC_TOKEN)), "small TOKEN exact-out open");
        assertTrue(_hookSwap(h, key, attacker, false, -int256(NO_KYC_USDC)), "small USDC exact-in open");
        assertTrue(_hookSwap(h, key, attacker, true, int256(NO_KYC_USDC)), "small USDC exact-out open");

        // Bands apply per currency.
        assertTrue(_hookSwap(h, key, retail, false, -int256(500e6)), "retail 500 USDC");
        assertFalse(_hookSwap(h, key, retail, false, -int256(2_000e6)), "retail above USDC enhanced");
        assertTrue(_hookSwap(h, key, accredited, false, -int256(2_000e6)), "accredited above enhanced");
        assertFalse(_hookSwap(h, key, retail, true, -int256(2e18)), "retail above TOKEN enhanced");
    }

    /// Every one of the four swap shapes is read in the right currency.
    function testFuzz_Issue3_New_FourShapesUseTheirCurrency(uint128 raw, bool zeroForOne, bool exactIn) public {
        vm.assume(raw > 0);
        (, ThresholdPolicyV4 policy,, PoolId poolId) =
            _thresholdV4(NO_KYC_TOKEN, ENHANCED_TOKEN, NO_KYC_USDC, ENHANCED_USDC, DENIED, RETAIL);
        int256 amountSpecified = exactIn ? -int256(uint256(raw)) : int256(uint256(raw));
        bool inUsdc = zeroForOne != exactIn;
        uint256 limit = inUsdc ? NO_KYC_USDC : NO_KYC_TOKEN;
        uint256 encoded = LexifiSwapAmount.encode(zeroForOne, amountSpecified);
        assertEq(
            _passes(ILexifiPolicy(address(policy)), poolId, attacker, OP_SWAP, encoded),
            uint256(raw) <= limit,
            "unverified passes exactly when at or below its currency's no-KYC limit"
        );
    }

    function testFuzz_Issue3_EncodeDecodeRoundTrip(int256 amountSpecified, bool zeroForOne) public pure {
        uint256 encoded = LexifiSwapAmount.encode(zeroForOne, amountSpecified);
        (uint256 magnitude, bool inCurrency1) = LexifiSwapAmount.decode(encoded);
        bool exactIn = amountSpecified < 0;
        assertEq(inCurrency1, zeroForOne != exactIn, "currency");
        if (amountSpecified == type(int256).min) {
            assertEq(magnitude, LexifiSwapAmount.MAGNITUDE_MASK, "saturates upward");
        } else {
            assertEq(magnitude, uint256(exactIn ? -amountSpecified : amountSpecified), "magnitude");
        }
    }

    /// A plain amount (flag clear) is currency0, as ILexifiPolicy documents. Integrators
    /// calling the adapter keep working, and can state currency1 with the flag.
    function test_Issue3_New_AdapterPlainAmountIsCurrency0() public {
        (LexifiHookV4 hook,, , PoolId poolId) =
            _thresholdV4(NO_KYC_TOKEN, ENHANCED_TOKEN, NO_KYC_USDC, ENHANCED_USDC, DENIED, RETAIL);
        LexifiComplianceAdapter adapter = new LexifiComplianceAdapter(address(hook));
        bytes32 pid = PoolId.unwrap(poolId);
        (bool small,,,) = adapter.checkCompliance(pid, attacker, OP_SWAP, NO_KYC_TOKEN);
        (bool usdcTagged,,,) =
            adapter.checkCompliance(pid, attacker, OP_SWAP, LexifiSwapAmount.encodeCurrency(HUGE_USDC, true));
        assertTrue(small, "plain amount at the currency0 limit passes");
        assertFalse(usdcTagged, "tagged 100M USDC denied");
    }

    /// HookV4 with a policy that reads `amount` but not the flag fails closed, never open.
    function test_Issue3_New_HookV4WithThresholdV3FailsClosed() public {
        LexifiHookV4 hook = _deployV4();
        LexifiPolicyConfigV2 registry = new LexifiPolicyConfigV2(IPoolAdminSource(address(hook)));
        ThresholdPolicyV3 policy = new ThresholdPolicyV3(address(provider), address(registry));
        PoolKey memory key = _key(address(hook));
        vm.startPrank(issuer);
        hook.createPool(key, SQRT_PRICE_1_1, address(policy));
        registry.setConfig(
            policy.CONFIG_FAMILY(), key.toId(), policy.encodeConfig(NO_KYC_TOKEN, ENHANCED_TOKEN, DENIED, RETAIL)
        );
        vm.stopPrank();
        assertFalse(_hookSwap(address(hook), key, attacker, false, -int256(HUGE_USDC)), "unverified denied");
        assertFalse(_hookSwap(address(hook), key, retail, false, -1), "retail denied: reads as large");
        assertTrue(_hookSwap(address(hook), key, accredited, false, -1), "accredited passes");
    }

    // ═══════════════════════════════════════════
    //  ISSUE 4 — policy squatting through the adapter on LexifiHook v1
    // ═══════════════════════════════════════════

    function _venueKey(address venueHook) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x4200000000000000000000000000000000000006)),
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(venueHook)
        });
    }

    /// Old: anyone registers a third-party venue's pool on LexifiHook v1 and picks its policy.
    function test_Issue4_Old_HookV1_AdapterServesSquattersPolicy() public {
        MockPoolManager mockPM = new MockPoolManager();
        LexifiHook hook = new LexifiHook(IPoolManager(address(mockPM)), lexifiSafe);
        LexifiComplianceAdapter adapter = new LexifiComplianceAdapter(address(hook));
        MockAqua0V4Adapter venue = new MockAqua0V4Adapter(address(adapter));
        PoolKey memory key = _venueKey(address(venue));
        bytes32 pid = PoolId.unwrap(key.toId());

        AdmitAllPolicy evil = new AdmitAllPolicy();
        vm.prank(attacker);
        hook.setPoolPolicy(key, address(evil));
        assertEq(hook.poolAdmin(key.toId()), attacker, "bug: attacker is pool admin");

        (bool allowed,,,) = adapter.checkCompliance(pid, attacker, OP_SWAP, 1_000_000e18);
        assertTrue(allowed, "bug: adapter admits via squatted policy");
        assertTrue(venue.simulateBeforeSwap(pid, attacker, 1_000_000e18, hex"01"), "bug: venue admits");
    }

    function test_Issue4_New_HookV4_NoSquatting() public {
        LexifiHookV4 hook = _deployV4();
        LexifiPolicyConfigV2 registry = new LexifiPolicyConfigV2(IPoolAdminSource(address(hook)));
        ThresholdPolicyV4 threshold = new ThresholdPolicyV4(address(provider), address(registry));
        LexifiComplianceAdapter adapter = new LexifiComplianceAdapter(address(hook));
        MockAqua0V4Adapter venue = new MockAqua0V4Adapter(address(adapter));
        AdmitAllPolicy evil = new AdmitAllPolicy();

        // A pool on another hook cannot be registered at all.
        PoolKey memory foreign = _venueKey(address(venue));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(LexifiHookV4.NotPoolAdmin.selector, attacker, foreign.toId()));
        hook.setPoolPolicy(foreign, address(evil));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(LexifiHookV4.WrongHook.selector, address(venue)));
        hook.createPool(foreign, SQRT_PRICE_1_1, address(evil));
        assertFalse(adapter.hasPolicy(PoolId.unwrap(foreign.toId())), "venue must check hasPolicy");

        // The venue's pool on Lexifi: created by the venue admin, who is bound as its admin.
        PoolKey memory key = _key(address(hook));
        PoolId poolId = key.toId();
        bytes32 pid = PoolId.unwrap(poolId);
        vm.startPrank(issuer);
        hook.createPool(key, SQRT_PRICE_1_1, address(threshold));
        registry.setConfig(
            threshold.CONFIG_FAMILY(), poolId, threshold.encodeConfig(100e18, 10_000e18, 100e6, 10_000e6, RETAIL, RETAIL)
        );
        vm.stopPrank();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(LexifiHookV4.NotPoolAdmin.selector, attacker, poolId));
        hook.setPoolPolicy(key, address(evil));
        vm.prank(lexifiSafe);
        vm.expectRevert(abi.encodeWithSelector(LexifiHookV4.NotPoolAdmin.selector, lexifiSafe, poolId));
        hook.setPoolPolicy(key, address(evil));

        // PoC harm assertions.
        (bool allowed,,,) = adapter.checkCompliance(pid, attacker, OP_SWAP, 1_000_000e18);
        assertFalse(allowed, "adapter denies unverified 1M swap");
        vm.expectRevert();
        venue.simulateBeforeSwap(pid, attacker, 1_000_000e18, hex"01");
        assertTrue(venue.simulateBeforeSwap(pid, retail, 1e18, hex"01"), "verified trader not bricked");
    }
}
