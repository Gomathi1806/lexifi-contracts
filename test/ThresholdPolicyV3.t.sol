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
import {LexifiHookV3} from "../src/LexifiHookV3.sol";
import {LexifiPolicyConfigV2, IPoolAdminSource} from "../src/LexifiPolicyConfigV2.sol";
import {ILexifiPolicy} from "../src/interfaces/ILexifiPolicy.sol";
import {ThresholdPolicy} from "../src/policies/ThresholdPolicy.sol";
import {ThresholdPolicyV3} from "../src/policies/ThresholdPolicyV3.sol";
import {LexifiComplianceAdapter} from "../src/integrations/LexifiComplianceAdapter.sol";
import {MockVerificationProvider} from "./mocks/MockVerificationProvider.sol";

/// @title ThresholdPolicyV3: admin binding, fail-closed default, threshold bands
/// @dev Verdicts go through the enforcement comparison (LexifiComplianceAdapter), never `reason`.
contract ThresholdPolicyV3Test is Test {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint8 constant OP_SWAP = 0;
    uint8 constant OP_LP = 1;
    uint8 constant OP_REMOVE = 2;

    uint256 constant NO_KYC = 1_000e6;
    uint256 constant ENHANCED = 10_000e6;

    PoolManager manager;
    LexifiHookV3 hook;
    LexifiPolicyConfigV2 registry;
    ThresholdPolicyV3 threshold;
    MockVerificationProvider provider;
    LexifiComplianceAdapter compliance;

    address lexifiSafe = makeAddr("lexifiSafe");
    address issuer = makeAddr("issuer");
    address issuer2 = makeAddr("issuer2");
    address attacker = makeAddr("attacker");
    address nobody = makeAddr("nobody"); // no attestation
    address retail = makeAddr("retail"); // tier 1
    address accredited = makeAddr("accredited"); // tier 2
    address staleRetail = makeAddr("staleRetail"); // tier 1 but verified = false

    PoolKey key;
    PoolId poolId;

    function setUp() public {
        manager = new PoolManager(address(this));

        address hookAddr = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG
            ) | (uint160(0x4444) << 144)
        );
        deployCodeTo(
            "LexifiHookV3.sol:LexifiHookV3",
            abi.encode(IPoolManager(address(manager)), lexifiSafe),
            hookAddr
        );
        hook = LexifiHookV3(hookAddr);

        registry = new LexifiPolicyConfigV2(IPoolAdminSource(address(hook)));
        provider = new MockVerificationProvider();
        threshold = new ThresholdPolicyV3(address(provider), address(registry));
        compliance = new LexifiComplianceAdapter(address(hook));

        provider.setUser(retail, 1, true);
        provider.setUser(accredited, 2, true);
        provider.setUser(staleRetail, 1, false);

        key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
    }

    // ═══════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════

    function _create(address creator) internal {
        vm.prank(creator);
        hook.createPool(key, SQRT_PRICE_1_1, address(threshold));
    }

    function _configure(
        address admin,
        uint256 noKyc,
        uint256 enhanced,
        ILexifiPolicy.AccessLevel lpMin,
        ILexifiPolicy.AccessLevel swapMin
    ) internal {
        bytes memory data = threshold.encodeConfig(noKyc, enhanced, lpMin, swapMin);
        bytes32 family = threshold.CONFIG_FAMILY();
        vm.prank(admin);
        registry.setConfig(family, poolId, data);
    }

    /// @dev The deployed Base config shape: RETAIL to swap above the limit and to LP.
    function _configureDefault() internal {
        _configure(
            issuer, NO_KYC, ENHANCED, ILexifiPolicy.AccessLevel.RETAIL, ILexifiPolicy.AccessLevel.RETAIL
        );
    }

    function _allowed(address user, uint8 op, uint256 amount) internal view returns (bool allowed) {
        (allowed,,,) = compliance.checkCompliance(PoolId.unwrap(poolId), user, op, amount);
    }

    // ═══════════════════════════════════════════
    //  THE GAP — reproduced on the deployed v1
    // ═══════════════════════════════════════════

    /// @dev v1 gives a pool's thresholds to whoever calls setPoolConfig first, for any pool id,
    ///      created or not. The attacker opens the pool (no KYC up to max) and the issuer,
    ///      arriving second, is locked out of their own pool's rules.
    function test_V1_FirstCallerTakesThePool() public {
        ThresholdPolicy v1 = new ThresholdPolicy(address(provider), lexifiSafe);

        vm.prank(attacker);
        v1.setPoolConfig(
            poolId,
            type(uint256).max,
            type(uint256).max,
            ILexifiPolicy.AccessLevel.DENIED,
            ILexifiPolicy.AccessLevel.DENIED
        );
        assertEq(v1.poolAdmins(poolId), attacker);

        vm.prank(issuer);
        vm.expectRevert(ThresholdPolicy.Unauthorized.selector);
        v1.setPoolConfig(
            poolId, NO_KYC, ENHANCED, ILexifiPolicy.AccessLevel.RETAIL, ILexifiPolicy.AccessLevel.RETAIL
        );

        // An unverified wallet now passes any swap size.
        (ILexifiPolicy.AccessLevel level,) = v1.checkAccess(poolId, nobody, OP_SWAP, 1e30);
        assertGe(uint8(level), uint8(v1.minimumLevel(poolId, OP_SWAP)));
    }

    /// @dev v1 with swapMinimum = DENIED ("no KYC below the enhanced limit"): the large-trade
    ///      check returns DENIED, but minimumLevel is also DENIED, so the comparison passes and an
    ///      unverified wallet makes a trade of any size.
    function test_V1_LargeTradeCheckIsNoOpWhenSwapMinimumDenied() public {
        ThresholdPolicy v1 = new ThresholdPolicy(address(provider), lexifiSafe);
        vm.prank(issuer);
        v1.setPoolConfig(
            poolId, NO_KYC, ENHANCED, ILexifiPolicy.AccessLevel.DENIED, ILexifiPolicy.AccessLevel.DENIED
        );
        (ILexifiPolicy.AccessLevel level, string memory reason) =
            v1.checkAccess(poolId, nobody, OP_SWAP, ENHANCED + 1);
        assertEq(reason, "Large trade requires enhanced verification");
        assertGe(uint8(level), uint8(v1.minimumLevel(poolId, OP_SWAP)), "yet the hook lets it through");
    }

    function test_LargeTradeCheckHoldsWhenSwapMinimumDenied() public {
        _create(issuer);
        _configure(
            issuer, NO_KYC, ENHANCED, ILexifiPolicy.AccessLevel.DENIED, ILexifiPolicy.AccessLevel.DENIED
        );
        assertTrue(_allowed(nobody, OP_SWAP, NO_KYC), "no-KYC band");
        assertTrue(_allowed(nobody, OP_SWAP, ENHANCED), "middle band is open by config");
        assertFalse(_allowed(nobody, OP_SWAP, ENHANCED + 1), "large trade still needs ACCREDITED");
        assertFalse(_allowed(retail, OP_SWAP, ENHANCED + 1));
        assertTrue(_allowed(accredited, OP_SWAP, ENHANCED + 1));
        assertTrue(_allowed(nobody, OP_LP, 1), "LP open by config");
    }

    // ═══════════════════════════════════════════
    //  THE FIX — config rights are the hook's pool admin
    // ═══════════════════════════════════════════

    function test_Attacker_CannotConfigureBeforePoolExists() public {
        bytes memory data = threshold.encodeConfig(
            type(uint256).max, type(uint256).max, ILexifiPolicy.AccessLevel.DENIED, ILexifiPolicy.AccessLevel.DENIED
        );
        bytes32 family = threshold.CONFIG_FAMILY();
        vm.prank(attacker);
        vm.expectRevert(LexifiPolicyConfigV2.Unauthorized.selector);
        registry.setConfig(family, poolId, data);

        _create(issuer);
        _configureDefault();
        assertFalse(_allowed(nobody, OP_SWAP, NO_KYC + 1));
    }

    function test_Attacker_CannotConfigureCreatedPool() public {
        _create(issuer);
        bytes memory data = threshold.encodeConfig(
            type(uint256).max, type(uint256).max, ILexifiPolicy.AccessLevel.DENIED, ILexifiPolicy.AccessLevel.DENIED
        );
        bytes32 family = threshold.CONFIG_FAMILY();
        vm.prank(attacker);
        vm.expectRevert(LexifiPolicyConfigV2.Unauthorized.selector);
        registry.setConfig(family, poolId, data);
    }

    function test_LexifiSafe_HasNoOverride() public {
        _create(issuer);
        bytes memory data = threshold.encodeConfig(0, 0, ILexifiPolicy.AccessLevel.DENIED, ILexifiPolicy.AccessLevel.DENIED);
        bytes32 family = threshold.CONFIG_FAMILY();
        vm.prank(lexifiSafe);
        vm.expectRevert(LexifiPolicyConfigV2.Unauthorized.selector);
        registry.setConfig(family, poolId, data);
    }

    function test_RightsMoveWithHookAdmin() public {
        _create(issuer);
        _configureDefault();

        vm.prank(issuer);
        hook.transferPoolAdmin(key, issuer2);

        bytes32 family = threshold.CONFIG_FAMILY();
        vm.prank(issuer);
        vm.expectRevert(LexifiPolicyConfigV2.Unauthorized.selector);
        registry.clearConfig(family, poolId);

        vm.prank(issuer2);
        registry.clearConfig(family, poolId);
        assertFalse(_allowed(accredited, OP_SWAP, NO_KYC + 1), "cleared config fails closed");
        assertFalse(_allowed(nobody, OP_SWAP, 1), "including the no-KYC band");
    }

    // ═══════════════════════════════════════════
    //  FAIL CLOSED
    // ═══════════════════════════════════════════

    function test_Unconfigured_DeniesEveryone() public {
        _create(issuer);
        assertFalse(_allowed(nobody, OP_SWAP, 1));
        assertFalse(_allowed(accredited, OP_SWAP, 1));
        assertFalse(_allowed(accredited, OP_LP, 1));
        assertEq(uint8(threshold.minimumLevel(poolId, OP_SWAP)), uint8(ILexifiPolicy.AccessLevel.INSTITUTIONAL));
    }

    function test_InactiveConfig_DeniesEveryone() public {
        _create(issuer);
        bytes memory data = abi.encode(
            ThresholdPolicyV3.ThresholdConfig({
                noKycLimit: type(uint256).max,
                enhancedLimit: type(uint256).max,
                lpMinimum: ILexifiPolicy.AccessLevel.DENIED,
                swapMinimum: ILexifiPolicy.AccessLevel.DENIED,
                active: false
            })
        );
        bytes32 family = threshold.CONFIG_FAMILY();
        vm.prank(issuer);
        registry.setConfig(family, poolId, data);
        assertFalse(_allowed(nobody, OP_SWAP, 1));
        assertFalse(_allowed(accredited, OP_LP, 1));
    }

    // ═══════════════════════════════════════════
    //  THRESHOLD BANDS
    // ═══════════════════════════════════════════

    function test_SmallSwap_OpenToAll() public {
        _create(issuer);
        _configureDefault();
        assertTrue(_allowed(nobody, OP_SWAP, NO_KYC));
        assertTrue(_allowed(nobody, OP_SWAP, 0));
    }

    function test_MidSwap_NeedsSwapMinimum() public {
        _create(issuer);
        _configureDefault();
        assertFalse(_allowed(nobody, OP_SWAP, NO_KYC + 1));
        assertFalse(_allowed(staleRetail, OP_SWAP, NO_KYC + 1), "unverified tier does not count");
        assertTrue(_allowed(retail, OP_SWAP, NO_KYC + 1));
        assertTrue(_allowed(retail, OP_SWAP, ENHANCED));
    }

    function test_LargeSwap_NeedsAccredited() public {
        _create(issuer);
        _configureDefault();
        assertFalse(_allowed(retail, OP_SWAP, ENHANCED + 1));
        assertTrue(_allowed(accredited, OP_SWAP, ENHANCED + 1));
    }

    function test_Lp_NeedsLpMinimum_RegardlessOfSize() public {
        _create(issuer);
        _configureDefault();
        assertFalse(_allowed(nobody, OP_LP, 1), "LP has no no-KYC band");
        assertFalse(_allowed(staleRetail, OP_LP, 1));
        assertTrue(_allowed(retail, OP_LP, 1));
    }

    function test_Remove_NeverGated() public {
        _create(issuer);
        _configureDefault();
        assertTrue(_allowed(nobody, OP_REMOVE, 1e30));
    }

    /// @dev Finding 1: lpMinimum below swapMinimum would let a wallet barred from mid-size swaps
    ///      acquire the asset by minting a position. It is clamped on read.
    function test_LpMinimumClampedToSwapMinimum() public {
        _create(issuer);
        _configure(
            issuer, NO_KYC, ENHANCED, ILexifiPolicy.AccessLevel.DENIED, ILexifiPolicy.AccessLevel.ACCREDITED
        );
        assertFalse(threshold.validateConfig(poolId));
        assertFalse(_allowed(retail, OP_LP, 1));
        assertTrue(_allowed(accredited, OP_LP, 1));
        (ThresholdPolicyV3.ThresholdConfig memory cfg,) = threshold.effectiveConfig(poolId);
        assertEq(uint8(cfg.lpMinimum), uint8(ILexifiPolicy.AccessLevel.ACCREDITED));
    }

    function test_ValidateConfig() public {
        _create(issuer);
        assertFalse(threshold.validateConfig(poolId), "unconfigured");
        _configureDefault();
        assertTrue(threshold.validateConfig(poolId));
        _configure(issuer, ENHANCED, NO_KYC, ILexifiPolicy.AccessLevel.RETAIL, ILexifiPolicy.AccessLevel.RETAIL);
        assertFalse(threshold.validateConfig(poolId), "enhanced below noKyc");
    }

    // ═══════════════════════════════════════════
    //  THROUGH THE HOOK
    // ═══════════════════════════════════════════

    function test_Hook_SwapEnforcedByAmount() public {
        _create(issuer);
        _configureDefault();

        IPoolManager.SwapParams memory small = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -int256(NO_KYC), sqrtPriceLimitX96: 0
        });
        IPoolManager.SwapParams memory mid = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -int256(NO_KYC + 1), sqrtPriceLimitX96: 0
        });

        vm.prank(address(manager));
        hook.beforeSwap(nobody, key, small, "");

        vm.prank(address(manager));
        vm.expectRevert();
        hook.beforeSwap(nobody, key, mid, "");

        vm.prank(address(manager));
        hook.beforeSwap(retail, key, mid, "");
    }

    // ═══════════════════════════════════════════
    //  FUZZ — the verdict matches the spec for any config, user and amount
    // ═══════════════════════════════════════════

    function _expected(
        uint256 noKyc,
        uint256 enhanced,
        uint8 lpMin,
        uint8 swapMin,
        uint8 tier,
        bool verified,
        uint8 op,
        uint256 amount
    ) internal pure returns (bool) {
        uint8 level = verified ? tier : 0;
        if (lpMin < swapMin) lpMin = swapMin;
        if (op == OP_SWAP) {
            if (amount <= noKyc) return true;
            if (amount > enhanced && level < 2) return false;
            return level >= swapMin;
        }
        if (op == OP_LP) return level >= lpMin;
        return true;
    }

    function testFuzz_VerdictMatchesSpec(
        uint256 noKyc,
        uint256 enhanced,
        uint8 lpMin,
        uint8 swapMin,
        uint8 tier,
        bool verified,
        uint8 op,
        uint256 amount
    ) public {
        lpMin = uint8(bound(lpMin, 0, 3));
        swapMin = uint8(bound(swapMin, 0, 3));
        tier = uint8(bound(tier, 0, 3));
        op = uint8(bound(op, 0, 2));

        _create(issuer);
        _configure(
            issuer, noKyc, enhanced, ILexifiPolicy.AccessLevel(lpMin), ILexifiPolicy.AccessLevel(swapMin)
        );
        address user = makeAddr("fuzzUser");
        provider.setUser(user, tier, verified);

        assertEq(
            _allowed(user, op, amount),
            _expected(noKyc, enhanced, lpMin, swapMin, tier, verified, op, amount)
        );
    }

    /// @dev Fail-closed holds for any user, operation and amount on an unconfigured pool —
    ///      except removeLiquidity, which is never gated.
    function testFuzz_UnconfiguredAlwaysDenies(uint8 tier, bool verified, uint8 op, uint256 amount) public {
        tier = uint8(bound(tier, 0, 3));
        op = uint8(bound(op, 0, 1));
        _create(issuer);
        address user = makeAddr("fuzzUser");
        provider.setUser(user, tier, verified);
        assertFalse(_allowed(user, op, amount));
    }
}
