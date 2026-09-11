// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
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
    BaseAllowlistChecker
} from "v4-periphery/src/hooks/permissionedPools/BaseAllowListChecker.sol";
import {
    PermissionFlag,
    PermissionFlags
} from "v4-periphery/src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {LexifiHook} from "../src/LexifiHook.sol";
import {ILexifiPolicy} from "../src/interfaces/ILexifiPolicy.sol";
import {ThresholdPolicy} from "../src/policies/ThresholdPolicy.sol";
import {LexifiComplianceAdapter} from "../src/integrations/LexifiComplianceAdapter.sol";
import {LexifiAllowlistChecker} from "../src/integrations/LexifiAllowlistChecker.sol";
import {ILexifiCompliance} from "../src/integrations/ILexifiCompliance.sol";
import {MockVerificationProvider} from "./mocks/MockVerificationProvider.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

/// @dev Stand-in for an issuer's restricted asset (a tokenized stock, say). A plain ERC-20 is
///      enough here: once the asset sits in Uniswap's adapter, the adapter holds it in custody.
contract MockSecurityToken is ERC20 {
    constructor() ERC20("Mock Stock Token", "mSTK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev What an issuer runs without Lexifi: a hand-maintained list. This one admits everyone.
contract OpenAllowlistChecker is BaseAllowlistChecker {
    function checkAllowlist(address, address) public pure override returns (PermissionFlag) {
        return PermissionFlags.ALL_ALLOWED;
    }
}

/// @title Permissions Adapter Integration Tests
/// @notice Drives Uniswap's real `PermissionsAdapterFactory` and `PermissionsAdapter`
///         (lib/v4-periphery/src/hooks/permissionedPools) with `LexifiAllowlistChecker` plugged in.
/// @dev `LexifiAllowlistChecker.t.sol` re-implements the adapter's bitmask rule to test the
///      checker on its own. This suite removes that stand-in: every verdict below comes from
///      Uniswap's own `isAllowed`, the checker is accepted by Uniswap's own ERC-165 probe, and
///      tokens move through Uniswap's own wrap/unwrap logic.
///
///      Still out of scope: a full swap through a concrete `PermissionedV4Router` against a live
///      PoolManager. The router is abstract at this periphery commit and the production
///      permissioned hook is not shipped in `src/`. The router's gate is a single
///      `isAllowed(msgSender(), SWAP_ALLOWED)` call on the adapter (PermissionedV4Router.sol:36),
///      and the position manager's is `isAllowed(recipient, LIQUIDITY_ALLOWED)`
///      (PermissionedPositionManager.sol:204). Both are made below against the real adapter.
contract PermissionsAdapterIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;

    // Lexifi stack
    MockPoolManager poolManager;
    LexifiHook hook;
    ThresholdPolicy thresholdPolicy;
    MockVerificationProvider provider;
    LexifiComplianceAdapter complianceAdapter;
    LexifiAllowlistChecker checker;

    // Uniswap stack
    PermissionsAdapterFactory factory;
    MockSecurityToken stock;
    IPermissionsAdapter adapter;

    address lexifiOwner = address(0xCAFE); // the Safe, in production
    address issuer = makeAddr("issuer"); // owns the PermissionsAdapter
    address router = makeAddr("router"); // an allowed wrapper, e.g. the Universal Router

    address unverified = makeAddr("unverified");
    address retail = makeAddr("retail");
    address accredited = makeAddr("accredited");
    address institutional = makeAddr("institutional");

    bytes32 poolIdBytes;

    uint256 constant NO_KYC_LIMIT = 100e18;
    uint256 constant ENHANCED_LIMIT = 10_000e18;

    function setUp() public {
        vm.startPrank(lexifiOwner);

        poolManager = new MockPoolManager();
        hook = new LexifiHook(IPoolManager(address(poolManager)), lexifiOwner);
        provider = new MockVerificationProvider();
        thresholdPolicy = new ThresholdPolicy(address(provider), lexifiOwner);
        complianceAdapter = new LexifiComplianceAdapter(address(hook));
        checker =
            new LexifiAllowlistChecker(ILexifiCompliance(address(complianceAdapter)), lexifiOwner);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x4200000000000000000000000000000000000006)),
            currency1: Currency.wrap(address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId poolId = key.toId();
        poolIdBytes = PoolId.unwrap(poolId);

        hook.setPoolPolicy(key, address(thresholdPolicy));
        thresholdPolicy.setPoolConfig(
            poolId,
            NO_KYC_LIMIT,
            ENHANCED_LIMIT,
            ILexifiPolicy.AccessLevel.RETAIL,
            ILexifiPolicy.AccessLevel.RETAIL
        );

        provider.setUser(retail, 1, true);
        provider.setUser(accredited, 2, true);
        provider.setUser(institutional, 3, true);

        vm.stopPrank();

        // Uniswap side: the real factory deploys the real adapter with the Lexifi checker.
        factory = new PermissionsAdapterFactory(address(poolManager));
        stock = new MockSecurityToken();
        adapter = _createAdapter(address(stock), address(checker));

        vm.prank(issuer);
        adapter.updateSwappingEnabled(true);

        // Lexifi side: the Safe binds the issuer's token to the pool whose policy governs it,
        // evaluated at the strictest notional that pool can demand.
        vm.prank(lexifiOwner);
        checker.bindToken(address(stock), poolIdBytes, type(uint256).max, true);
    }

    // ═══════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════

    function _createAdapter(address token, address allowlistChecker)
        internal
        returns (IPermissionsAdapter)
    {
        return IPermissionsAdapter(
            factory.createPermissionsAdapter(
                IERC20(token), issuer, IAllowlistChecker(allowlistChecker)
            )
        );
    }

    /// @dev The gate `PermissionedV4Router._pay` applies before paying a permissioned token in.
    function _routerAllowsSwap(IPermissionsAdapter a, address trader) internal view returns (bool) {
        return a.swappingEnabled() && a.isAllowed(trader, PermissionFlags.SWAP_ALLOWED);
    }

    /// @dev The gate `PermissionedPositionManager` applies to a liquidity recipient.
    function _positionManagerAllowsLiquidity(IPermissionsAdapter a, address lp)
        internal
        view
        returns (bool)
    {
        return a.isAllowed(lp, PermissionFlags.LIQUIDITY_ALLOWED);
    }

    /// @dev Put `amount` of the permissioned token into the pool manager the way a router does.
    function _wrapIntoPoolManager(uint256 amount) internal {
        stock.mint(issuer, amount);
        vm.startPrank(issuer);
        adapter.updateAllowedWrapper(router, true);
        stock.transfer(address(adapter), amount);
        vm.stopPrank();
        vm.prank(router);
        adapter.wrapToPoolManager(amount);
    }

    // ═══════════════════════════════════════════
    //  WIRING — Uniswap's own checks accept Lexifi
    // ═══════════════════════════════════════════

    function test_Factory_CreatesAdapterWithLexifiChecker() public view {
        assertEq(address(adapter.allowListChecker()), address(checker));
        assertEq(address(adapter.PERMISSIONED_TOKEN()), address(stock));
        assertEq(adapter.POOL_MANAGER(), address(poolManager));
        assertEq(adapter.owner(), issuer);
        assertEq(factory.permissionsAdapterOf(address(adapter)), address(stock));
    }

    function test_Factory_RejectsAContractThatIsNotAChecker() public {
        // The compliance adapter has no ERC-165 support, so Uniswap's probe must refuse it.
        // This is the negative control proving the probe above really ran.
        vm.expectRevert(
            abi.encodeWithSelector(
                IPermissionsAdapter.InvalidAllowListChecker.selector, address(complianceAdapter)
            )
        );
        factory.createPermissionsAdapter(
            IERC20(address(stock)), issuer, IAllowlistChecker(address(complianceAdapter))
        );
    }

    function test_Issuer_SwapsHandMaintainedListForLexifi() public {
        IPermissionsAdapter a = _createAdapter(address(stock), address(new OpenAllowlistChecker()));
        assertTrue(a.isAllowed(unverified, PermissionFlags.SWAP_ALLOWED), "open list admits anyone");

        vm.expectEmit(true, false, false, false, address(a));
        emit IPermissionsAdapter.AllowListCheckerUpdated(IAllowlistChecker(address(checker)));
        vm.prank(issuer);
        a.updateAllowListChecker(IAllowlistChecker(address(checker)));

        assertFalse(a.isAllowed(unverified, PermissionFlags.SWAP_ALLOWED), "Lexifi now decides");
        assertTrue(a.isAllowed(institutional, PermissionFlags.SWAP_ALLOWED));
    }

    function test_Issuer_CannotSwapInAContractThatIsNotAChecker() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IPermissionsAdapter.InvalidAllowListChecker.selector, address(complianceAdapter)
            )
        );
        vm.prank(issuer);
        adapter.updateAllowListChecker(IAllowlistChecker(address(complianceAdapter)));
    }

    // ═══════════════════════════════════════════
    //  VERDICTS — Lexifi policy, Uniswap enforcement
    // ═══════════════════════════════════════════

    function test_Institutional_CanSwapAndProvideLiquidity() public view {
        assertTrue(_routerAllowsSwap(adapter, institutional));
        assertTrue(_positionManagerAllowsLiquidity(adapter, institutional));
    }

    function test_Accredited_ClearsTheStrictestNotional() public view {
        assertTrue(_routerAllowsSwap(adapter, accredited));
        assertTrue(_positionManagerAllowsLiquidity(adapter, accredited));
    }

    function test_Retail_DeniedSwapAndTheLpBackdoor() public view {
        // Denied the swap at the pinned notional; `liquidityRequiresSwap` then withholds the LP
        // flag so the asset cannot be acquired by minting a position instead of buying it.
        assertFalse(_routerAllowsSwap(adapter, retail));
        assertFalse(_positionManagerAllowsLiquidity(adapter, retail));
    }

    function test_Unverified_DeniedEverything() public view {
        assertFalse(_routerAllowsSwap(adapter, unverified));
        assertFalse(_positionManagerAllowsLiquidity(adapter, unverified));
    }

    function test_LpOnlyBinding_AdmitsRetailLiquidityButNotSwaps() public {
        MockSecurityToken lpOnlyAsset = new MockSecurityToken();
        IPermissionsAdapter lpAdapter = _createAdapter(address(lpOnlyAsset), address(checker));
        vm.prank(issuer);
        lpAdapter.updateSwappingEnabled(true);
        vm.prank(lexifiOwner);
        checker.bindToken(address(lpOnlyAsset), poolIdBytes, type(uint256).max, false);

        assertFalse(_routerAllowsSwap(lpAdapter, retail));
        assertTrue(_positionManagerAllowsLiquidity(lpAdapter, retail));
    }

    // ═══════════════════════════════════════════
    //  FAIL-CLOSED — through the real adapter
    // ═══════════════════════════════════════════

    function test_PausedChecker_AdapterDeniesEveryone() public {
        vm.prank(lexifiOwner);
        checker.setPaused(true);

        assertFalse(_routerAllowsSwap(adapter, institutional));
        assertFalse(_positionManagerAllowsLiquidity(adapter, institutional));
    }

    function test_UnboundToken_AdapterDeniesEveryone() public {
        IPermissionsAdapter unbound =
            _createAdapter(address(new MockSecurityToken()), address(checker));

        assertFalse(unbound.isAllowed(institutional, PermissionFlags.SWAP_ALLOWED));
        assertFalse(unbound.isAllowed(institutional, PermissionFlags.LIQUIDITY_ALLOWED));
    }

    // ═══════════════════════════════════════════
    //  CUSTODY — tokens through Uniswap's wrap/unwrap
    // ═══════════════════════════════════════════

    function test_Lifecycle_VerifyWrapAndReleaseToCompliantTrader() public {
        // The issuer proves custody, and the factory marks the adapter verified. That is the
        // lookup PermissionedV4Router uses to decide a currency is permissioned at all.
        stock.mint(issuer, 1);
        vm.startPrank(issuer);
        stock.approve(address(adapter), 1);
        adapter.depositForVerification(1);
        vm.stopPrank();
        factory.verifyPermissionsAdapter(address(adapter));
        assertEq(factory.verifiedPermissionsAdapterOf(address(adapter)), address(stock));

        // The router only pays in for a trader the Lexifi policy allowlists.
        assertTrue(_routerAllowsSwap(adapter, institutional));
        assertFalse(_routerAllowsSwap(adapter, unverified));

        uint256 amount = 250e18;
        _wrapIntoPoolManager(amount);
        assertEq(IERC20(address(adapter)).balanceOf(address(poolManager)), amount);

        // The pool manager pays out; the adapter burns its wrapper and releases the real asset.
        vm.prank(address(poolManager));
        IERC20(address(adapter)).transfer(institutional, amount);

        assertEq(stock.balanceOf(institutional), amount);
        assertEq(IERC20(address(adapter)).totalSupply(), 0);
    }

    function test_PausedChecker_DoesNotTrapTokensAlreadyInThePool() public {
        uint256 amount = 100e18;
        _wrapIntoPoolManager(amount);

        // The issuer's kill switch stops new entries, but the release path never consults the
        // checker, so pausing Lexifi cannot strand tokens the pool already holds.
        vm.prank(lexifiOwner);
        checker.setPaused(true);

        vm.prank(address(poolManager));
        IERC20(address(adapter)).transfer(retail, amount);

        assertEq(stock.balanceOf(retail), amount);
    }

    // ═══════════════════════════════════════════
    //  PROPERTY — adapter, checker and preview agree
    // ═══════════════════════════════════════════

    /// @dev For any account at any tier: the real adapter's verdict is exactly the checker's flags
    ///      under Uniswap's bitmask rule, `previewPermissions` (the "why was I denied" surface)
    ///      never disagrees with it, and only ACCREDITED or above clears the pinned notional.
    function testFuzz_AdapterAgreesWithCheckerAndPreview(address account, uint8 tier) public {
        vm.assume(account != address(0));
        tier = uint8(bound(tier, 0, 3));
        vm.prank(lexifiOwner);
        provider.setUser(account, tier, tier > 0);

        PermissionFlag flags = checker.checkAllowlist(account, address(stock));
        bool swap = adapter.isAllowed(account, PermissionFlags.SWAP_ALLOWED);
        bool liquidity = adapter.isAllowed(account, PermissionFlags.LIQUIDITY_ALLOWED);

        assertEq(swap, (flags & PermissionFlags.SWAP_ALLOWED) == PermissionFlags.SWAP_ALLOWED);
        assertEq(
            liquidity,
            (flags & PermissionFlags.LIQUIDITY_ALLOWED) == PermissionFlags.LIQUIDITY_ALLOWED
        );

        (bool previewSwap, bool previewLiquidity,,,) =
            checker.previewPermissions(account, address(stock));
        assertEq(swap, previewSwap, "preview disagrees on swap");
        assertEq(liquidity, previewLiquidity, "preview disagrees on liquidity");

        assertEq(swap, tier >= 2, "swap tier");
        assertEq(liquidity, tier >= 2, "liquidity is coupled to swap on this binding");
    }
}
