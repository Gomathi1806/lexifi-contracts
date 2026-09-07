// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {
    IAllowlistChecker
} from "v4-periphery/src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
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

/// @notice Compliance source that always reverts — proves the checker fails closed.
contract RevertingCompliance is ILexifiCompliance {
    function checkCompliance(bytes32, address, uint8, uint256)
        external
        pure
        returns (bool, uint8, uint8, string memory)
    {
        revert("policy exploded");
    }

    function hasPolicy(bytes32) external pure returns (bool) {
        return true;
    }
}

/// @notice Compliance source with independently settable swap / liquidity answers.
contract AsymmetricCompliance is ILexifiCompliance {
    bool public swapAllowed;
    bool public liquidityAllowed;

    function set(bool _swap, bool _liquidity) external {
        swapAllowed = _swap;
        liquidityAllowed = _liquidity;
    }

    function checkCompliance(bytes32, address, uint8 operation, uint256)
        external
        view
        returns (bool, uint8, uint8, string memory)
    {
        bool allowed = operation == 0 ? swapAllowed : liquidityAllowed;
        return (allowed, allowed ? 3 : 0, 1, allowed ? "" : "denied");
    }

    function hasPolicy(bytes32) external pure returns (bool) {
        return true;
    }
}

/// @title LexifiAllowlistChecker Tests
/// @notice Proves Lexifi policies can drive a Uniswap v4 Permissioned Pool's allowlist.
/// @dev The real stack (LexifiHook → ThresholdPolicy → provider) is wired up in setUp so the
///      tests exercise the same path a deployed PermissionsAdapter would.
contract LexifiAllowlistCheckerTest is Test {
    using PoolIdLibrary for PoolKey;

    MockPoolManager poolManager;
    LexifiHook hook;
    LexifiComplianceAdapter complianceAdapter;
    LexifiAllowlistChecker checker;
    ThresholdPolicy thresholdPolicy;
    MockVerificationProvider provider;

    address owner = address(0xCAFE);
    address stranger = address(0xBEEF);
    address verifiedTrader = address(0x1111);
    address unverifiedTrader = address(0x2222);
    address institutionalTrader = address(0x3333);

    /// @dev Stands in for the issuer's permissioned token (the adapter's PERMISSIONED_TOKEN).
    address permissionedToken = address(0xA55E7);
    address unrelatedToken = address(0xDEAD);

    PoolKey poolKey;
    PoolId poolId;
    bytes32 poolIdBytes;

    uint256 constant NO_KYC_LIMIT = 100e18;
    uint256 constant ENHANCED_LIMIT = 10_000e18;

    function setUp() public {
        vm.startPrank(owner);

        poolManager = new MockPoolManager();
        hook = new LexifiHook(IPoolManager(address(poolManager)), owner);
        provider = new MockVerificationProvider();
        thresholdPolicy = new ThresholdPolicy(address(provider), owner);
        complianceAdapter = new LexifiComplianceAdapter(address(hook));
        checker = new LexifiAllowlistChecker(ILexifiCompliance(address(complianceAdapter)), owner);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x4200000000000000000000000000000000000006)),
            currency1: Currency.wrap(address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        poolIdBytes = PoolId.unwrap(poolId);

        hook.setPoolPolicy(poolKey, address(thresholdPolicy));
        thresholdPolicy.setPoolConfig(
            poolId,
            NO_KYC_LIMIT,
            ENHANCED_LIMIT,
            ILexifiPolicy.AccessLevel.RETAIL,
            ILexifiPolicy.AccessLevel.RETAIL
        );

        // Evaluate at the strictest notional this pool can demand.
        checker.bindToken(permissionedToken, poolIdBytes, type(uint256).max, true);

        provider.setUser(verifiedTrader, 1, true); // RETAIL
        provider.setUser(institutionalTrader, 3, true); // INSTITUTIONAL
        // unverifiedTrader stays at tier 0

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════
    //  HELPERS — mirror PermissionsAdapter._hasPermission
    // ═══════════════════════════════════════════

    function _flags(address account, address token) internal view returns (uint16) {
        return uint16(PermissionFlag.unwrap(checker.checkAllowlist(account, token)));
    }

    /// @dev PermissionsAdapter checks `(checkAllowlist(acct, tkn) & permission) == permission`.
    function _hasPermission(address account, address token, PermissionFlag permission)
        internal
        view
        returns (bool)
    {
        return (checker.checkAllowlist(account, token) & permission) == permission;
    }

    // ═══════════════════════════════════════════
    //  CORE: real Lexifi stack drives the allowlist
    // ═══════════════════════════════════════════

    function test_InstitutionalTrader_GetsAllPermissions() public view {
        assertTrue(
            _hasPermission(institutionalTrader, permissionedToken, PermissionFlags.SWAP_ALLOWED)
        );
        assertTrue(
            _hasPermission(
                institutionalTrader, permissionedToken, PermissionFlags.LIQUIDITY_ALLOWED
            )
        );
        assertEq(_flags(institutionalTrader, permissionedToken), 0x0003);
    }

    /// @dev A RETAIL user is denied because the binding evaluates at max notional, which trips
    ///      ThresholdPolicy's "large trade requires enhanced verification" branch. This is the
    ///      intended conservative reading of a size-blind interface.
    function test_RetailTrader_DeniedAtMaxNotional() public view {
        assertFalse(_hasPermission(verifiedTrader, permissionedToken, PermissionFlags.SWAP_ALLOWED));
        assertEq(_flags(verifiedTrader, permissionedToken), 0x0000);
    }

    /// @dev Regression guard for a real hole. ThresholdPolicy gates swaps on trade size but gates
    ///      LPs on tier alone, so a RETAIL address denied a max-notional swap still clears the raw
    ///      LP check — it could acquire the permissioned asset by minting a position instead of
    ///      buying it. `liquidityRequiresSwap` closes that; opting out re-opens it deliberately.
    function test_LiquidityRequiresSwap_ClosesTheLpBackdoor() public {
        // Underlying policy really does say "LP: yes" for this address.
        (, uint8 lpTier,,) =
            complianceAdapter.checkCompliance(poolIdBytes, verifiedTrader, 1, type(uint256).max);
        assertEq(lpTier, uint8(ILexifiPolicy.AccessLevel.RETAIL));

        // Coupled (default): no swap ⇒ no liquidity.
        assertEq(_flags(verifiedTrader, permissionedToken), 0x0000);

        // Decoupled: the LP-only backdoor reappears.
        vm.prank(owner);
        checker.bindToken(permissionedToken, poolIdBytes, type(uint256).max, false);
        assertEq(_flags(verifiedTrader, permissionedToken), 0x0002);
    }

    function test_UnverifiedTrader_GetsNothing() public view {
        assertEq(_flags(unverifiedTrader, permissionedToken), 0x0000);
        assertFalse(
            _hasPermission(unverifiedTrader, permissionedToken, PermissionFlags.SWAP_ALLOWED)
        );
        assertFalse(
            _hasPermission(unverifiedTrader, permissionedToken, PermissionFlags.LIQUIDITY_ALLOWED)
        );
    }

    /// @dev Documents the evaluationAmount lever: lowering it below the enhanced limit lets a
    ///      RETAIL user through. This is why 0 is rejected at bind time — it would open the pool.
    function test_EvaluationAmount_ChangesTheAnswer() public {
        assertEq(_flags(verifiedTrader, permissionedToken), 0x0000);

        vm.prank(owner);
        checker.setEvaluationAmount(permissionedToken, ENHANCED_LIMIT);

        assertEq(_flags(verifiedTrader, permissionedToken), 0x0003);
    }

    // ═══════════════════════════════════════════
    //  FAIL-CLOSED BEHAVIOUR
    // ═══════════════════════════════════════════

    function test_UnboundToken_ReturnsNone() public view {
        assertEq(_flags(institutionalTrader, unrelatedToken), 0x0000);
    }

    function test_Paused_DeniesEveryone() public {
        assertEq(_flags(institutionalTrader, permissionedToken), 0x0003);

        vm.prank(owner);
        checker.setPaused(true);

        assertEq(_flags(institutionalTrader, permissionedToken), 0x0000);
    }

    function test_UnboundAfterBinding_ReturnsNone() public {
        vm.prank(owner);
        checker.unbindToken(permissionedToken);

        assertEq(_flags(institutionalTrader, permissionedToken), 0x0000);
        assertFalse(checker.isTokenGoverned(permissionedToken));
    }

    /// @dev A reverting policy must not bubble up — that would brick the pool, exits included.
    function test_RevertingPolicy_FailsClosedInsteadOfReverting() public {
        vm.startPrank(owner);
        LexifiAllowlistChecker fragile = new LexifiAllowlistChecker(
            ILexifiCompliance(address(new RevertingCompliance())), owner
        );
        fragile.bindToken(permissionedToken, poolIdBytes, type(uint256).max, true);
        vm.stopPrank();

        PermissionFlag flags = fragile.checkAllowlist(institutionalTrader, permissionedToken);
        assertEq(uint16(PermissionFlag.unwrap(flags)), 0x0000);
    }

    // ═══════════════════════════════════════════
    //  FLAG INDEPENDENCE
    // ═══════════════════════════════════════════

    /// @dev "The right to buy an asset should not confer the right to be its market maker."
    function test_SwapAndLiquidityFlagsAreIndependent() public {
        AsymmetricCompliance mock = new AsymmetricCompliance();
        vm.startPrank(owner);
        LexifiAllowlistChecker split =
            new LexifiAllowlistChecker(ILexifiCompliance(address(mock)), owner);
        split.bindToken(permissionedToken, poolIdBytes, 1, false);
        vm.stopPrank();

        mock.set(true, false);
        assertEq(
            uint16(PermissionFlag.unwrap(split.checkAllowlist(stranger, permissionedToken))), 0x0001
        );

        mock.set(false, true);
        assertEq(
            uint16(PermissionFlag.unwrap(split.checkAllowlist(stranger, permissionedToken))), 0x0002
        );

        mock.set(true, true);
        assertEq(
            uint16(PermissionFlag.unwrap(split.checkAllowlist(stranger, permissionedToken))), 0x0003
        );
    }

    // ═══════════════════════════════════════════
    //  ERC165 — PermissionsAdapter rejects checkers that fail this
    // ═══════════════════════════════════════════

    function test_SupportsIAllowlistCheckerInterface() public view {
        assertTrue(checker.supportsInterface(type(IAllowlistChecker).interfaceId));
        assertFalse(checker.supportsInterface(0xdeadbeef));
    }

    // ═══════════════════════════════════════════
    //  ADMIN
    // ═══════════════════════════════════════════

    function test_BindToken_RejectsZeroEvaluationAmount() public {
        vm.prank(owner);
        vm.expectRevert(LexifiAllowlistChecker.ZeroEvaluationAmount.selector);
        checker.bindToken(unrelatedToken, poolIdBytes, 0, true);
    }

    function test_BindToken_RejectsZeroToken() public {
        vm.prank(owner);
        vm.expectRevert(LexifiAllowlistChecker.ZeroAddress.selector);
        checker.bindToken(address(0), poolIdBytes, 1e18, true);
    }

    function test_SetEvaluationAmount_RevertsForUnboundToken() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(LexifiAllowlistChecker.TokenNotBound.selector, unrelatedToken)
        );
        checker.setEvaluationAmount(unrelatedToken, 1e18);
    }

    function test_OnlyOwner_CanBind() public {
        vm.prank(stranger);
        vm.expectRevert(LexifiAllowlistChecker.OnlyOwner.selector);
        checker.bindToken(unrelatedToken, poolIdBytes, 1e18, true);
    }

    function test_OnlyOwner_CanPause() public {
        vm.prank(stranger);
        vm.expectRevert(LexifiAllowlistChecker.OnlyOwner.selector);
        checker.setPaused(true);
    }

    function test_TransferOwnership() public {
        vm.prank(owner);
        checker.transferOwnership(stranger);
        assertEq(checker.owner(), stranger);

        vm.prank(stranger);
        checker.setPaused(true);
        assertTrue(checker.paused());
    }

    // ═══════════════════════════════════════════
    //  VIEWS
    // ═══════════════════════════════════════════

    function test_PreviewPermissions_SurfacesDenialReason() public view {
        (bool swapAllowed,,,, string memory reason) =
            checker.previewPermissions(verifiedTrader, permissionedToken);

        assertFalse(swapAllowed);
        assertEq(reason, "Large trade requires enhanced verification");
    }

    function test_PreviewPermissions_UnboundToken() public view {
        (bool swapAllowed, bool liquidityAllowed,,, string memory reason) =
            checker.previewPermissions(institutionalTrader, unrelatedToken);

        assertFalse(swapAllowed);
        assertFalse(liquidityAllowed);
        assertEq(reason, "Token not bound");
    }

    function test_IsTokenGoverned() public view {
        assertTrue(checker.isTokenGoverned(permissionedToken));
        assertFalse(checker.isTokenGoverned(unrelatedToken));
    }
}
