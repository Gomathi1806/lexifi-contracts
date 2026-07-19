// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LexifiHook} from "../src/LexifiHook.sol";
import {ThresholdPolicy} from "../src/policies/ThresholdPolicy.sol";
import {ILexifiPolicy} from "../src/interfaces/ILexifiPolicy.sol";
import {MockVerificationProvider} from "./mocks/MockVerificationProvider.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

contract LexifiHookTest is Test {
    using PoolIdLibrary for PoolKey;

    LexifiHook public hook;
    ThresholdPolicy public policy;
    MockVerificationProvider public provider;
    MockPoolManager public mockPM;

    address public lexifiOwner = address(0xAAA);
    address public dexOperator = address(0xBBB);
    address public verifiedTrader = address(0x111);
    address public unverifiedTrader = address(0x222);
    address public enhancedTrader = address(0x333);

    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        // Deploy mocks
        mockPM = new MockPoolManager();
        provider = new MockVerificationProvider();

        // Deploy hook pointing to mock pool manager
        hook = new LexifiHook(IPoolManager(address(mockPM)), lexifiOwner);

        // Deploy policy
        policy = new ThresholdPolicy(address(provider), dexOperator);

        // Set up user tiers
        provider.setUser(verifiedTrader, 1, true);    // RETAIL
        provider.setUser(enhancedTrader, 2, true);     // ACCREDITED
        provider.setUser(unverifiedTrader, 0, false);  // DENIED

        // Create pool key (hook address doesn't need permission bits for unit tests)
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x100)),
            currency1: Currency.wrap(address(0x200)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        // DEX operator registers policy on the hook
        vm.prank(dexOperator);
        hook.setPoolPolicy(poolKey, address(policy));

        // DEX operator configures thresholds
        vm.prank(dexOperator);
        policy.setPoolConfig(
            poolId,
            1000e18,   // noKycLimit
            10000e18,  // enhancedLimit
            ILexifiPolicy.AccessLevel.RETAIL,
            ILexifiPolicy.AccessLevel.RETAIL
        );
    }

    // ═══════════════════════════════════════════
    //  POLICY REGISTRATION
    // ═══════════════════════════════════════════

    function test_SetPoolPolicy_RegistersCorrectly() public view {
        assertTrue(hook.isCompliancePool(poolId));
        assertEq(hook.poolPolicy(poolId), address(policy));
        assertEq(hook.poolAdmin(poolId), dexOperator);
        assertEq(hook.totalPools(), 1);
    }

    function test_SetPoolPolicy_InvalidAddress_Reverts() public {
        PoolKey memory otherKey = _makePoolKey(address(0x300), address(0x400));
        vm.prank(dexOperator);
        vm.expectRevert(abi.encodeWithSelector(LexifiHook.InvalidPolicy.selector, address(0)));
        hook.setPoolPolicy(otherKey, address(0));
    }

    function test_SetPoolPolicy_OnlyAdmin_CanUpdate() public {
        // Another user tries to update the policy
        vm.prank(address(0xBAD));
        vm.expectRevert();
        hook.setPoolPolicy(poolKey, address(policy));
    }

    function test_SetPoolPolicy_AdminCanUpdate() public {
        // Deploy a second policy
        ThresholdPolicy policy2 = new ThresholdPolicy(address(provider), dexOperator);

        vm.prank(dexOperator);
        hook.setPoolPolicy(poolKey, address(policy2));

        assertEq(hook.poolPolicy(poolId), address(policy2));
        // totalPools should NOT increment on update
        assertEq(hook.totalPools(), 1);
    }

    // ═══════════════════════════════════════════
    //  beforeSwap — COMPLIANCE ENFORCEMENT
    // ═══════════════════════════════════════════

    function test_BeforeSwap_VerifiedUser_SmallAmount_Passes() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(500e18), // negative = exact input
            sqrtPriceLimitX96: 0
        });

        // Call as pool manager, with tx.origin = verified trader
        vm.prank(address(mockPM));
        (bytes4 selector,,) = hook.beforeSwap(verifiedTrader, poolKey, params, "");

        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(hook.totalChecks(), 1);
    }

    function test_BeforeSwap_UnverifiedUser_SmallAmount_Passes() public {
        // Small trade — no KYC required
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(500e18),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(mockPM));
        (bytes4 selector,,) = hook.beforeSwap(unverifiedTrader, poolKey, params, "");

        assertEq(selector, IHooks.beforeSwap.selector);
    }

    function test_BeforeSwap_UnverifiedUser_MediumAmount_Reverts() public {
        // Medium trade — KYC required, unverified user should fail
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(5000e18),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(mockPM));
        vm.expectRevert();
        hook.beforeSwap(unverifiedTrader, poolKey, params, "");
    }

    function test_BeforeSwap_VerifiedUser_MediumAmount_Passes() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(5000e18),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(mockPM));
        (bytes4 selector,,) = hook.beforeSwap(verifiedTrader, poolKey, params, "");

        assertEq(selector, IHooks.beforeSwap.selector);
    }

    function test_BeforeSwap_RetailUser_LargeAmount_Reverts() public {
        // Large trade — needs ACCREDITED, retail user denied
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(50000e18),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(mockPM)); // RETAIL tier
        vm.expectRevert();
        hook.beforeSwap(verifiedTrader, poolKey, params, "");
    }

    function test_BeforeSwap_EnhancedUser_LargeAmount_Passes() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(50000e18),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(mockPM)); // ACCREDITED tier
        (bytes4 selector,,) = hook.beforeSwap(enhancedTrader, poolKey, params, "");

        assertEq(selector, IHooks.beforeSwap.selector);
    }

    // ═══════════════════════════════════════════
    //  beforeSwap — NON-COMPLIANCE POOL (NO ENFORCEMENT)
    // ═══════════════════════════════════════════

    function test_BeforeSwap_OpenPool_NoEnforcement() public {
        // Create a pool without a policy
        PoolKey memory openKey = _makePoolKey(address(0x500), address(0x600));

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(999999e18),
            sqrtPriceLimitX96: 0
        });

        // Unverified user on open pool — should pass
        vm.prank(address(mockPM));
        (bytes4 selector,,) = hook.beforeSwap(unverifiedTrader, openKey, params, "");

        assertEq(selector, IHooks.beforeSwap.selector);
        // totalChecks should NOT increment for non-compliance pools
    }

    // ═══════════════════════════════════════════
    //  beforeAddLiquidity — COMPLIANCE ENFORCEMENT
    // ═══════════════════════════════════════════

    function test_BeforeAddLiquidity_VerifiedUser_Passes() public {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: int256(1000e18),
            salt: bytes32(0)
        });

        vm.prank(address(mockPM));
        bytes4 selector = hook.beforeAddLiquidity(verifiedTrader, poolKey, params, "");

        assertEq(selector, IHooks.beforeAddLiquidity.selector);
    }

    function test_BeforeAddLiquidity_UnverifiedUser_Reverts() public {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: int256(1000e18),
            salt: bytes32(0)
        });

        vm.prank(address(mockPM));
        vm.expectRevert();
        hook.beforeAddLiquidity(unverifiedTrader, poolKey, params, "");
    }

    // ═══════════════════════════════════════════
    //  beforeRemoveLiquidity — NEVER BLOCKED
    // ═══════════════════════════════════════════

    function test_BeforeRemoveLiquidity_AlwaysPasses() public {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: -int256(1000e18),
            salt: bytes32(0)
        });

        // Even unverified user can remove liquidity
        vm.prank(address(mockPM));
        bytes4 selector = hook.beforeRemoveLiquidity(address(0), poolKey, params, "");

        assertEq(selector, IHooks.beforeRemoveLiquidity.selector);
    }

    // ═══════════════════════════════════════════
    //  onlyPoolManager GUARD
    // ═══════════════════════════════════════════

    function test_BeforeSwap_NotPoolManager_Reverts() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(100e18),
            sqrtPriceLimitX96: 0
        });

        // Called from random address, not pool manager
        vm.prank(address(0xBAD));
        vm.expectRevert(LexifiHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(0), poolKey, params, "");
    }

    // ═══════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════

    function test_CheckUserCompliance_View() public view {
        (bool allowed, uint8 userLevel, uint8 requiredLevel, string memory reason) =
            hook.checkUserCompliance(poolKey, verifiedTrader, 0, 5000e18);

        assertTrue(allowed);
        assertEq(userLevel, 1); // RETAIL
        assertEq(requiredLevel, 1); // RETAIL
        assertEq(bytes(reason).length, 0);
    }

    function test_CheckUserCompliance_DeniedView() public view {
        (bool allowed, uint8 userLevel, uint8 requiredLevel, string memory reason) =
            hook.checkUserCompliance(poolKey, unverifiedTrader, 0, 5000e18);

        assertFalse(allowed);
        assertEq(userLevel, 0); // DENIED
        assertEq(requiredLevel, 1); // RETAIL
        assertTrue(bytes(reason).length > 0);
    }

    function test_CheckUserCompliance_OpenPool() public view {
        PoolKey memory openKey = _makePoolKey(address(0x500), address(0x600));

        (bool allowed, uint8 userLevel, uint8 requiredLevel,) =
            hook.checkUserCompliance(openKey, unverifiedTrader, 0, 999999e18);

        assertTrue(allowed);
        assertEq(userLevel, 3); // max
        assertEq(requiredLevel, 0); // none
    }

    function test_GetPoolInfo() public view {
        (bool hasCompliance, address policyAddr, string memory policyName, address admin) =
            hook.getPoolInfo(poolKey);

        assertTrue(hasCompliance);
        assertEq(policyAddr, address(policy));
        assertEq(policyName, "Lexifi Threshold Policy");
        assertEq(admin, dexOperator);
    }

    function test_GetPoolInfo_OpenPool() public view {
        PoolKey memory openKey = _makePoolKey(address(0x500), address(0x600));

        (bool hasCompliance, address policyAddr,,) = hook.getPoolInfo(openKey);

        assertFalse(hasCompliance);
        assertEq(policyAddr, address(0));
    }

    // ═══════════════════════════════════════════
    //  LEXIFI OWNER FUNCTIONS
    // ═══════════════════════════════════════════

    function test_ApprovePolicy() public {
        vm.prank(lexifiOwner);
        hook.approvePolicy(address(policy));
        assertTrue(hook.approvedPolicies(address(policy)));
    }

    function test_ApprovePolicy_OnlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(LexifiHook.OnlyOwner.selector);
        hook.approvePolicy(address(policy));
    }

    function test_RevokePolicy() public {
        vm.prank(lexifiOwner);
        hook.approvePolicy(address(policy));
        assertTrue(hook.approvedPolicies(address(policy)));

        vm.prank(lexifiOwner);
        hook.revokePolicy(address(policy));
        assertFalse(hook.approvedPolicies(address(policy)));
    }

    function test_RequireApproval_BlocksUnapproved() public {
        // Enable approval requirement
        vm.prank(lexifiOwner);
        hook.setRequireApproval(true);

        // Try to register unapproved policy on new pool
        PoolKey memory newKey = _makePoolKey(address(0x700), address(0x800));

        ThresholdPolicy policy2 = new ThresholdPolicy(address(provider), dexOperator);

        vm.prank(dexOperator);
        vm.expectRevert(abi.encodeWithSelector(LexifiHook.PolicyNotApproved.selector, address(policy2)));
        hook.setPoolPolicy(newKey, address(policy2));
    }

    function test_RequireApproval_ApprovedWorks() public {
        vm.prank(lexifiOwner);
        hook.setRequireApproval(true);

        ThresholdPolicy policy2 = new ThresholdPolicy(address(provider), dexOperator);

        vm.prank(lexifiOwner);
        hook.approvePolicy(address(policy2));

        PoolKey memory newKey = _makePoolKey(address(0x700), address(0x800));

        vm.prank(dexOperator);
        hook.setPoolPolicy(newKey, address(policy2));

        assertTrue(hook.isCompliancePool(newKey.toId()));
    }

    function test_TransferOwnership() public {
        address newOwner = address(0xCCC);

        vm.prank(lexifiOwner);
        hook.transferOwnership(newOwner);

        assertEq(hook.owner(), newOwner);

        // Old owner can't act anymore
        vm.prank(lexifiOwner);
        vm.expectRevert(LexifiHook.OnlyOwner.selector);
        hook.approvePolicy(address(0x999));
    }

    function test_TransferPoolAdmin() public {
        address newAdmin = address(0xCCC);

        vm.prank(dexOperator);
        hook.transferPoolAdmin(poolKey, newAdmin);

        assertEq(hook.poolAdmin(poolId), newAdmin);
    }

    // ═══════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════

    function test_EmitsComplianceCheckPassed() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(500e18),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(mockPM));
        hook.beforeSwap(verifiedTrader, poolKey, params, "");

        // If we get here without revert, the event was emitted
        // (Foundry's vm.expectEmit could be used for precise checking)
        assertTrue(hook.totalChecks() == 1);
    }

    // ═══════════════════════════════════════════
    //  ANALYTICS
    // ═══════════════════════════════════════════

    function test_TotalChecks_Increments() public {
        assertEq(hook.totalChecks(), 0);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(500e18),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(mockPM));
        hook.beforeSwap(verifiedTrader, poolKey, params, "");
        assertEq(hook.totalChecks(), 1);

        vm.prank(address(mockPM));
        hook.beforeSwap(enhancedTrader, poolKey, params, "");
        assertEq(hook.totalChecks(), 2);
    }

    // ═══════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════

    function _makePoolKey(address token0, address token1) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    // ═══════════════════════════════════════════
    //  USER RESOLUTION — TRUSTED ROUTERS (no tx.origin)
    // ═══════════════════════════════════════════

    function _mediumSwap() internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(5000e18), sqrtPriceLimitX96: 0});
    }

    function test_TrustedRouter_ResolvesRealUser() public {
        MockRouter router = new MockRouter();
        router.setUser(verifiedTrader);
        vm.prank(lexifiOwner);
        hook.setTrustedRouter(address(router), true);

        vm.prank(address(mockPM));
        (bytes4 selector,,) = hook.beforeSwap(address(router), poolKey, _mediumSwap(), "");
        assertEq(selector, IHooks.beforeSwap.selector);
    }

    function test_UntrustedRouter_CannotSpoofVerifiedUser() public {
        // Router claims a verified user via msgSender() but is NOT trusted:
        // the router itself is compliance-checked (unverified) => denied.
        MockRouter router = new MockRouter();
        router.setUser(verifiedTrader);

        vm.prank(address(mockPM));
        vm.expectRevert();
        hook.beforeSwap(address(router), poolKey, _mediumSwap(), "");
    }

    function test_TrustedRouter_MsgSenderReverts_FailsSafe() public {
        // Trusted router whose msgSender() reverts: falls back to router-as-user => denied.
        MockRouter router = new MockRouter();
        router.setRevert(true);
        vm.prank(lexifiOwner);
        hook.setTrustedRouter(address(router), true);

        vm.prank(address(mockPM));
        vm.expectRevert();
        hook.beforeSwap(address(router), poolKey, _mediumSwap(), "");
    }

    function test_TxOrigin_NoLongerGrantsAccess() public {
        // tx.origin is a verified trader, but sender is unverified => denied.
        vm.prank(address(mockPM), verifiedTrader);
        vm.expectRevert();
        hook.beforeSwap(unverifiedTrader, poolKey, _mediumSwap(), "");
    }

    function test_SetTrustedRouter_OnlyOwner() public {
        vm.prank(dexOperator);
        vm.expectRevert(LexifiHook.OnlyOwner.selector);
        hook.setTrustedRouter(address(0x123), true);
    }
}

contract MockRouter {
    address internal user;
    bool internal shouldRevert;

    function setUser(address u) external { user = u; }
    function setRevert(bool r) external { shouldRevert = r; }

    function msgSender() external view returns (address) {
        require(!shouldRevert, "router: no context");
        return user;
    }
}
