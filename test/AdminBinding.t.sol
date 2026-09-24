// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {
    PermissionsAdapterFactory
} from "v4-periphery/src/hooks/permissionedPools/PermissionsAdapterFactory.sol";
import {
    IPermissionsAdapter
} from "v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {
    IAllowlistChecker
} from "v4-periphery/src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {
    PermissionFlag,
    PermissionFlags
} from "v4-periphery/src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {LexifiHookV3} from "../src/LexifiHookV3.sol";
import {LexifiPolicyConfigV2, IPoolAdminSource} from "../src/LexifiPolicyConfigV2.sol";
import {ILexifiPolicy} from "../src/interfaces/ILexifiPolicy.sol";
import {RegionalPolicyV3} from "../src/policies/RegionalPolicyV3.sol";
import {LexifiComplianceAdapter} from "../src/integrations/LexifiComplianceAdapter.sol";
import {ILexifiCompliance} from "../src/integrations/ILexifiCompliance.sol";
import {LexifiAllowlistCheckerV2} from "../src/integrations/LexifiAllowlistCheckerV2.sol";
import {MockVerificationProvider} from "./mocks/MockVerificationProvider.sol";

contract MockAsset is ERC20 {
    constructor() ERC20("Mock Asset", "mAST") {}
}

/// @title Pool-admin binding: LexifiHookV3, LexifiPolicyConfigV2, LexifiAllowlistCheckerV2
/// @dev Closes the two gaps in the deployed stack:
///        1. `setPoolPolicy` / `setConfig` gave admin to the first caller (claimable by anyone).
///        2. `bindToken` was owner-only (the Lexifi Safe had to act for every issuer).
///      Runs against Uniswap's real PoolManager and PermissionsAdapterFactory. Access verdicts
///      go through the enforcement comparison (LexifiComplianceAdapter / adapter.isAllowed).
contract AdminBindingTest is Test {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint8 constant OP_SWAP = 0;
    uint8 constant OP_LP = 1;

    PoolManager manager;
    LexifiHookV3 hook;
    LexifiPolicyConfigV2 registry;
    RegionalPolicyV3 regional;
    RegionalPolicyV3 regional2;
    MockVerificationProvider provider;
    LexifiComplianceAdapter compliance;
    LexifiAllowlistCheckerV2 checker;
    PermissionsAdapterFactory factory;
    MockAsset asset;

    address lexifiSafe = makeAddr("lexifiSafe");
    address issuer = makeAddr("issuer");
    address issuer2 = makeAddr("issuer2");
    address attacker = makeAddr("attacker");
    address verified = makeAddr("verified");
    address unverified = makeAddr("unverified");

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
        regional = new RegionalPolicyV3(address(provider), address(registry), lexifiSafe);
        regional2 = new RegionalPolicyV3(address(provider), address(registry), lexifiSafe);
        compliance = new LexifiComplianceAdapter(address(hook));
        checker = new LexifiAllowlistCheckerV2(ILexifiCompliance(address(compliance)));
        factory = new PermissionsAdapterFactory(address(manager));
        asset = new MockAsset();

        provider.setUser(verified, 2, true);
        provider.setUser(unverified, 0, false);

        key = _key(3000);
        poolId = key.toId();
    }

    // ═══════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════

    function _key(uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _create(address creator, PoolKey memory k) internal {
        vm.prank(creator);
        hook.createPool(k, SQRT_PRICE_1_1, address(regional));
    }

    /// @dev Regional config: no country/account requirement, ACCREDITED (2) for swap and LP.
    function _configure(address admin, PoolId id) internal {
        bytes32 family = regional.CONFIG_FAMILY();
        bytes memory data = regional.encodeConfig(
            false, false, ILexifiPolicy.AccessLevel.ACCREDITED, ILexifiPolicy.AccessLevel.ACCREDITED
        );
        vm.prank(admin);
        registry.setConfig(family, id, data);
    }

    function _allowed(PoolId id, address user, uint8 op) internal view returns (bool allowed) {
        (allowed,,,) = compliance.checkCompliance(PoolId.unwrap(id), user, op, 0);
    }

    function _adapter(address owner_) internal returns (IPermissionsAdapter) {
        return IPermissionsAdapter(
            factory.createPermissionsAdapter(
                IERC20(address(asset)), owner_, IAllowlistChecker(address(checker))
            )
        );
    }

    // ═══════════════════════════════════════════
    //  GAP 1a — hook: admin is the pool's creator
    // ═══════════════════════════════════════════

    function test_Hook_CreatePool_CreatorIsAdmin() public {
        _create(issuer, key);
        assertEq(hook.poolAdmin(poolId), issuer);
        assertEq(hook.poolPolicy(poolId), address(regional));
        assertTrue(hook.isCompliancePool(poolId));
        assertEq(hook.totalPools(), 1);
        (, int24 tick,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(tick, 0, "pool initialized on the real PoolManager");
    }

    /// @dev The old attack: claim an announced pool before it exists. Nothing to claim now.
    function test_Hook_CannotClaimPoolBeforeItExists() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(LexifiHookV3.NotPoolAdmin.selector, attacker, poolId));
        hook.setPoolPolicy(key, address(regional));

        // The issuer's own creation still goes through afterwards.
        _create(issuer, key);
        assertEq(hook.poolAdmin(poolId), issuer);
    }

    function test_Hook_CannotTakeOverExistingPool() public {
        _create(issuer, key);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(LexifiHookV3.NotPoolAdmin.selector, attacker, poolId));
        hook.setPoolPolicy(key, address(regional2));
        assertEq(hook.poolPolicy(poolId), address(regional));
    }

    /// @dev Initializing directly on the PoolManager would create a pool with no admin.
    function test_Hook_DirectInitializeRejected() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(LexifiHookV3.InitializeViaCreatePool.selector, attacker),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_Hook_SecondCreateOfSameKeyReverts() public {
        _create(issuer, key);
        vm.prank(attacker);
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        hook.createPool(key, SQRT_PRICE_1_1, address(regional2));
        assertEq(hook.poolAdmin(poolId), issuer);
    }

    function test_Hook_CreatePool_WrongHookReverts() public {
        PoolKey memory k = key;
        k.hooks = IHooks(address(0xdead));
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(LexifiHookV3.WrongHook.selector, address(0xdead)));
        hook.createPool(k, SQRT_PRICE_1_1, address(regional));
    }

    function test_Hook_CreatePool_InvalidPolicyReverts() public {
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(LexifiHookV3.InvalidPolicy.selector, address(0)));
        hook.createPool(key, SQRT_PRICE_1_1, address(0));
    }

    function test_Hook_RequireApproval_Enforced() public {
        vm.prank(lexifiSafe);
        hook.setRequireApproval(true);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(LexifiHookV3.PolicyNotApproved.selector, address(regional)));
        hook.createPool(key, SQRT_PRICE_1_1, address(regional));

        vm.prank(lexifiSafe);
        hook.approvePolicy(address(regional));
        _create(issuer, key);
        assertEq(hook.poolAdmin(poolId), issuer);
    }

    function test_Hook_AdminChangesPolicy() public {
        _create(issuer, key);
        vm.prank(issuer);
        hook.setPoolPolicy(key, address(regional2));
        assertEq(hook.poolPolicy(poolId), address(regional2));
        assertEq(hook.totalPools(), 1, "a policy change is not a new pool");
    }

    function test_Hook_TransferPoolAdmin() public {
        _create(issuer, key);
        vm.prank(issuer);
        hook.transferPoolAdmin(key, issuer2);
        assertEq(hook.poolAdmin(poolId), issuer2);

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(LexifiHookV3.NotPoolAdmin.selector, issuer, poolId));
        hook.setPoolPolicy(key, address(regional2));

        vm.prank(issuer2);
        hook.setPoolPolicy(key, address(regional2));
    }

    function test_Hook_TransferPoolAdmin_ZeroReverts() public {
        _create(issuer, key);
        vm.prank(issuer);
        vm.expectRevert(LexifiHookV3.ZeroAddress.selector);
        hook.transferPoolAdmin(key, address(0));
    }

    /// @dev Enforcement is unchanged from LexifiHook: a denied user's swap reverts in beforeSwap.
    function test_Hook_EnforcementUnchanged() public {
        _create(issuer, key);
        _configure(issuer, poolId);
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        vm.prank(address(manager));
        vm.expectRevert();
        hook.beforeSwap(unverified, key, params, "");

        vm.prank(address(manager));
        hook.beforeSwap(verified, key, params, "");
    }

    // ═══════════════════════════════════════════
    //  GAP 1b — registry: config rights follow the hook's pool admin
    // ═══════════════════════════════════════════

    function test_Registry_CannotClaimConfigOfUncreatedPool() public {
        bytes32 family = regional.CONFIG_FAMILY();
        vm.prank(attacker);
        vm.expectRevert(LexifiPolicyConfigV2.Unauthorized.selector);
        registry.setConfig(family, poolId, hex"01");
    }

    function test_Registry_StrangerCannotWriteCreatedPool() public {
        _create(issuer, key);
        bytes32 family = regional.CONFIG_FAMILY();
        vm.prank(attacker);
        vm.expectRevert(LexifiPolicyConfigV2.Unauthorized.selector);
        registry.setConfig(family, poolId, hex"01");
    }

    function test_Registry_AdminConfigures_EnforcedThroughPolicy() public {
        _create(issuer, key);
        assertFalse(_allowed(poolId, verified, OP_SWAP), "unconfigured pool fails closed");

        _configure(issuer, poolId);
        assertTrue(_allowed(poolId, verified, OP_SWAP));
        assertTrue(_allowed(poolId, verified, OP_LP));
        assertFalse(_allowed(poolId, unverified, OP_SWAP));
        assertFalse(_allowed(poolId, unverified, OP_LP));
    }

    function test_Registry_RightsMoveWithHookAdmin() public {
        _create(issuer, key);
        _configure(issuer, poolId);

        vm.prank(issuer);
        hook.transferPoolAdmin(key, issuer2);
        assertEq(registry.poolAdmin(poolId), issuer2);

        bytes32 family = regional.CONFIG_FAMILY();
        vm.prank(issuer);
        vm.expectRevert(LexifiPolicyConfigV2.Unauthorized.selector);
        registry.clearConfig(family, poolId);

        vm.prank(issuer2);
        registry.clearConfig(family, poolId);
        assertFalse(_allowed(poolId, verified, OP_SWAP), "cleared config fails closed");
    }

    function test_Registry_LexifiSafeHasNoOverride() public {
        _create(issuer, key);
        bytes32 family = regional.CONFIG_FAMILY();
        vm.prank(lexifiSafe);
        vm.expectRevert(LexifiPolicyConfigV2.Unauthorized.selector);
        registry.setConfig(family, poolId, hex"01");
    }

    function test_Registry_Batch() public {
        PoolKey memory k2 = _key(500);
        _create(issuer, key);
        _create(issuer, k2);

        PoolId[] memory ids = new PoolId[](2);
        ids[0] = poolId;
        ids[1] = k2.toId();
        bytes[] memory datas = new bytes[](2);
        datas[0] = regional.encodeConfig(
            false, false, ILexifiPolicy.AccessLevel.ACCREDITED, ILexifiPolicy.AccessLevel.ACCREDITED
        );
        datas[1] = datas[0];
        bytes32 family = regional.CONFIG_FAMILY();

        vm.prank(issuer);
        registry.setConfigBatch(family, ids, datas);
        assertTrue(_allowed(k2.toId(), verified, OP_SWAP));

        // One pool the caller does not administer sinks the whole batch.
        PoolKey memory k3 = _key(100);
        _create(attacker, k3);
        ids[1] = k3.toId();
        vm.prank(issuer);
        vm.expectRevert(LexifiPolicyConfigV2.Unauthorized.selector);
        registry.setConfigBatch(family, ids, datas);
    }

    // ═══════════════════════════════════════════
    //  GAP 2 — allowlist checker: issuer self-serve binding
    // ═══════════════════════════════════════════

    function _issuerPool() internal returns (IPermissionsAdapter a) {
        _create(issuer, key);
        _configure(issuer, poolId);
        a = _adapter(issuer);
        vm.prank(issuer);
        a.updateSwappingEnabled(true);
    }

    function test_Checker_IssuerBindsOwnAdapter() public {
        IPermissionsAdapter a = _issuerPool();
        vm.prank(issuer);
        checker.bind(address(a), PoolId.unwrap(poolId), type(uint256).max, true);

        assertTrue(checker.isGoverned(address(a)));
        assertTrue(a.isAllowed(verified, PermissionFlags.SWAP_ALLOWED));
        assertTrue(a.isAllowed(verified, PermissionFlags.LIQUIDITY_ALLOWED));
        assertFalse(a.isAllowed(unverified, PermissionFlags.SWAP_ALLOWED));
        assertFalse(a.isAllowed(unverified, PermissionFlags.LIQUIDITY_ALLOWED));
    }

    function test_Checker_UnboundAdapterDeniesAll() public {
        IPermissionsAdapter a = _issuerPool();
        assertFalse(a.isAllowed(verified, PermissionFlags.SWAP_ALLOWED));
        assertFalse(checker.isGoverned(address(a)));
    }

    function test_Checker_StrangerCannotBind() public {
        IPermissionsAdapter a = _issuerPool();
        bytes32 pid = PoolId.unwrap(poolId);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(LexifiAllowlistCheckerV2.NotAdapterOwner.selector, attacker, address(a))
        );
        checker.bind(address(a), pid, type(uint256).max, true);
    }

    /// @dev No Lexifi key sits in the path any more.
    function test_Checker_LexifiSafeCannotBind() public {
        IPermissionsAdapter a = _issuerPool();
        bytes32 pid = PoolId.unwrap(poolId);
        vm.prank(lexifiSafe);
        vm.expectRevert(
            abi.encodeWithSelector(LexifiAllowlistCheckerV2.NotAdapterOwner.selector, lexifiSafe, address(a))
        );
        checker.bind(address(a), pid, type(uint256).max, true);
    }

    function test_Checker_BindToPoolWithoutPolicyReverts() public {
        IPermissionsAdapter a = _issuerPool();
        bytes32 missing = PoolId.unwrap(_key(100).toId());
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(LexifiAllowlistCheckerV2.NoPolicyForPool.selector, missing));
        checker.bind(address(a), missing, type(uint256).max, true);
    }

    function test_Checker_ZeroEvaluationAmountReverts() public {
        IPermissionsAdapter a = _issuerPool();
        bytes32 pid = PoolId.unwrap(poolId);
        vm.prank(issuer);
        vm.expectRevert(LexifiAllowlistCheckerV2.ZeroEvaluationAmount.selector);
        checker.bind(address(a), pid, 0, true);
    }

    /// @dev Two issuers wrapping the same token: separate bindings, no overwrite.
    function test_Checker_SameTokenTwoIssuersIndependent() public {
        IPermissionsAdapter a = _issuerPool();
        vm.prank(issuer);
        checker.bind(address(a), PoolId.unwrap(poolId), type(uint256).max, true);

        IPermissionsAdapter b = _adapter(issuer2);
        assertFalse(b.isAllowed(verified, PermissionFlags.SWAP_ALLOWED), "b not bound yet");

        vm.prank(issuer2);
        vm.expectRevert(
            abi.encodeWithSelector(LexifiAllowlistCheckerV2.NotAdapterOwner.selector, issuer2, address(a))
        );
        checker.unbind(address(a));

        assertTrue(a.isAllowed(verified, PermissionFlags.SWAP_ALLOWED), "a unaffected");
    }

    /// @dev Someone calling the checker directly (not an adapter) has no binding.
    function test_Checker_DirectCallerGetsNone() public {
        IPermissionsAdapter a = _issuerPool();
        vm.prank(issuer);
        checker.bind(address(a), PoolId.unwrap(poolId), type(uint256).max, true);

        vm.prank(attacker);
        PermissionFlag f = checker.checkAllowlist(verified, address(asset));
        assertEq(PermissionFlag.unwrap(f), PermissionFlag.unwrap(PermissionFlags.NONE));
        assertEq(
            PermissionFlag.unwrap(checker.flagsFor(address(a), verified)),
            PermissionFlag.unwrap(PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED)
        );
    }

    /// @dev A bound adapter asked about a different token gets NONE.
    function test_Checker_TokenMismatchGetsNone() public {
        IPermissionsAdapter a = _issuerPool();
        vm.prank(issuer);
        checker.bind(address(a), PoolId.unwrap(poolId), type(uint256).max, true);

        vm.prank(address(a));
        PermissionFlag f = checker.checkAllowlist(verified, address(0xBEEF));
        assertEq(PermissionFlag.unwrap(f), PermissionFlag.unwrap(PermissionFlags.NONE));
    }

    function test_Checker_PauseAndUnbind() public {
        IPermissionsAdapter a = _issuerPool();
        vm.prank(issuer);
        checker.bind(address(a), PoolId.unwrap(poolId), type(uint256).max, true);

        vm.prank(issuer);
        checker.setPaused(address(a), true);
        assertFalse(a.isAllowed(verified, PermissionFlags.SWAP_ALLOWED));
        (,,,, string memory reason) = checker.previewPermissions(address(a), verified);
        assertEq(reason, "Binding paused");

        vm.prank(issuer);
        checker.setPaused(address(a), false);
        assertTrue(a.isAllowed(verified, PermissionFlags.SWAP_ALLOWED));

        vm.prank(issuer);
        checker.unbind(address(a));
        assertFalse(a.isAllowed(verified, PermissionFlags.SWAP_ALLOWED));
    }

    /// @dev Binding authority follows the adapter's current owner.
    function test_Checker_AdapterOwnershipTransferMovesAuthority() public {
        IPermissionsAdapter a = _issuerPool();
        vm.prank(issuer);
        checker.bind(address(a), PoolId.unwrap(poolId), type(uint256).max, true);

        // PermissionsAdapter is Ownable2Step: transfer, then accept.
        vm.prank(issuer);
        (bool ok,) = address(a).call(abi.encodeWithSignature("transferOwnership(address)", issuer2));
        assertTrue(ok);
        vm.prank(issuer2);
        (ok,) = address(a).call(abi.encodeWithSignature("acceptOwnership()"));
        assertTrue(ok);

        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(LexifiAllowlistCheckerV2.NotAdapterOwner.selector, issuer, address(a))
        );
        checker.setPaused(address(a), true);

        vm.prank(issuer2);
        checker.setPaused(address(a), true);
        assertFalse(a.isAllowed(verified, PermissionFlags.SWAP_ALLOWED));
    }

    /// @dev LP back door stays closed: denied a swap means denied liquidity.
    function test_Checker_PreviewMatchesAdapter() public {
        IPermissionsAdapter a = _issuerPool();
        vm.prank(issuer);
        checker.bind(address(a), PoolId.unwrap(poolId), type(uint256).max, true);

        (bool s, bool l,,,) = checker.previewPermissions(address(a), unverified);
        assertEq(s, a.isAllowed(unverified, PermissionFlags.SWAP_ALLOWED));
        assertEq(l, a.isAllowed(unverified, PermissionFlags.LIQUIDITY_ALLOWED));
        (s, l,,,) = checker.previewPermissions(address(a), verified);
        assertEq(s, a.isAllowed(verified, PermissionFlags.SWAP_ALLOWED));
        assertEq(l, a.isAllowed(verified, PermissionFlags.LIQUIDITY_ALLOWED));
    }
}
