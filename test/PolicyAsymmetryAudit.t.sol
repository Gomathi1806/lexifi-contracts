// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PermissionFlag} from
    "v4-periphery/src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {LexifiHook} from "../src/LexifiHook.sol";
import {ILexifiPolicy} from "../src/interfaces/ILexifiPolicy.sol";
import {RegionalPolicy} from "../src/policies/RegionalPolicy.sol";
import {InstitutionalPolicy} from "../src/policies/InstitutionalPolicy.sol";
import {ThresholdPolicy} from "../src/policies/ThresholdPolicy.sol";
import {LexifiComplianceAdapter} from "../src/integrations/LexifiComplianceAdapter.sol";
import {LexifiAllowlistChecker} from "../src/integrations/LexifiAllowlistChecker.sol";
import {ILexifiCompliance} from "../src/integrations/ILexifiCompliance.sol";
import {MockVerificationProvider} from "./mocks/MockVerificationProvider.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

/// @title Policy audit — swap/LP asymmetry and requirement enforcement
/// @notice Follow-up to the hole found in ThresholdPolicy while building LexifiAllowlistChecker.
/// @dev Every assertion here goes through the real enforcement comparison
///      (`checkAccess().level >= minimumLevel(operation)`) via LexifiComplianceAdapter, NOT
///      through `checkAccess` alone. Asserting on the returned `reason` string proves nothing:
///      the hook discards it whenever the level comparison passes, which is exactly how
///      `test_PartiallyVerified_OnlyOneProvider_Denied` in InstitutionalPolicy.t.sol reports
///      green on a case that is not actually denied.
contract PolicyAsymmetryAuditTest is Test {
    using PoolIdLibrary for PoolKey;

    MockPoolManager poolManager;
    LexifiHook hook;
    LexifiComplianceAdapter complianceAdapter;
    RegionalPolicy regionalPolicy;
    InstitutionalPolicy institutionalPolicy;
    ThresholdPolicy thresholdPolicy;
    MockVerificationProvider provider;
    MockVerificationProvider provider2;
    MockVerificationProvider provider3;

    address owner = address(0xCAFE);
    address retailUser = address(0x1111);
    address accreditedUser = address(0x2222);

    PoolKey regionalKey;
    PoolKey institutionalKey;
    PoolKey thresholdKey;
    bytes32 regionalPoolId;
    bytes32 institutionalPoolId;
    bytes32 thresholdPoolId;

    uint8 constant OP_SWAP = 0;
    uint8 constant OP_LP = 1;

    function setUp() public {
        vm.startPrank(owner);

        poolManager = new MockPoolManager();
        hook = new LexifiHook(IPoolManager(address(poolManager)), owner);
        provider = new MockVerificationProvider();
        provider2 = new MockVerificationProvider();
        provider3 = new MockVerificationProvider();
        regionalPolicy = new RegionalPolicy(address(provider), owner);
        institutionalPolicy = new InstitutionalPolicy(owner);
        thresholdPolicy = new ThresholdPolicy(address(provider), owner);
        complianceAdapter = new LexifiComplianceAdapter(address(hook));

        regionalKey = _key(3000);
        institutionalKey = _key(500);
        thresholdKey = _key(10000);
        regionalPoolId = PoolId.unwrap(regionalKey.toId());
        institutionalPoolId = PoolId.unwrap(institutionalKey.toId());
        thresholdPoolId = PoolId.unwrap(thresholdKey.toId());

        hook.setPoolPolicy(regionalKey, address(regionalPolicy));
        hook.setPoolPolicy(institutionalKey, address(institutionalPolicy));
        hook.setPoolPolicy(thresholdKey, address(thresholdPolicy));

        provider.setUser(retailUser, 1, true); // RETAIL, account-verified only
        provider.setUser(accreditedUser, 2, true); // ACCREDITED

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

    /// @dev The real gate: what LexifiHook and LexifiAllowlistChecker both act on.
    function _allowed(bytes32 poolId, address user, uint8 operation) internal view returns (bool) {
        return _allowedAt(poolId, user, operation, 0);
    }

    /// @dev Same gate, at a specific notional — ThresholdPolicy is the one policy that reads it.
    function _allowedAt(bytes32 poolId, address user, uint8 operation, uint256 amount)
        internal
        view
        returns (bool)
    {
        (bool allowed,,,) = complianceAdapter.checkCompliance(poolId, user, operation, amount);
        return allowed;
    }

    // ═══════════════════════════════════════════
    //  FINDING 1 — RegionalPolicy: same asymmetry as ThresholdPolicy
    // ═══════════════════════════════════════════

    /// @dev FIXED. `checkAccess` ignores `operation`, so swap and LP differ only through
    ///      `minimumLevel`. `setRegionConfig` used to accept minSwap and minLp independently with
    ///      no ordering constraint, so an admin setting minLp < minSwap reopened the LP backdoor:
    ///      an address barred from buying the asset could still mint a position in it. The config
    ///      that creates the divergence is now rejected outright.
    function test_Finding1_RegionalPolicy_RejectsMinLpBelowMinSwap() public {
        vm.prank(owner);
        vm.expectRevert(RegionalPolicy.LpBelowSwapMinimum.selector);
        regionalPolicy.setRegionConfig(
            regionalKey.toId(),
            false,
            false,
            ILexifiPolicy.AccessLevel.ACCREDITED, // minSwap
            ILexifiPolicy.AccessLevel.RETAIL // minLp  <-- below minSwap, now rejected
        );
    }

    /// @dev minLp ABOVE minSwap is still allowed — stricter liquidity than swapping is a
    ///      legitimate configuration. Only the backdoor direction is barred.
    function test_Finding1_RegionalPolicy_AllowsMinLpAboveMinSwap() public {
        vm.prank(owner);
        regionalPolicy.setRegionConfig(
            regionalKey.toId(),
            false,
            false,
            ILexifiPolicy.AccessLevel.RETAIL, // minSwap
            ILexifiPolicy.AccessLevel.ACCREDITED // minLp  <-- stricter, fine
        );

        assertTrue(_allowed(regionalPoolId, retailUser, OP_SWAP), "retail may swap");
        assertFalse(_allowed(regionalPoolId, retailUser, OP_LP), "retail may not LP");
        assertTrue(_allowed(regionalPoolId, accreditedUser, OP_LP), "accredited may LP");
    }

    /// @dev Not vulnerable when configured sanely — unlike ThresholdPolicy, which opens the hole
    ///      even with matched minimums because its amount branch applies to swaps only.
    function test_Finding1_RegionalPolicy_SafeWhenMinimumsMatch() public {
        vm.prank(owner);
        regionalPolicy.setRegionConfig(
            regionalKey.toId(),
            false,
            false,
            ILexifiPolicy.AccessLevel.ACCREDITED,
            ILexifiPolicy.AccessLevel.ACCREDITED
        );

        assertFalse(_allowed(regionalPoolId, retailUser, OP_SWAP));
        assertFalse(_allowed(regionalPoolId, retailUser, OP_LP));
    }

    // ═══════════════════════════════════════════
    //  FINDING 2 — RegionalPolicy: requireCountryAttestation does not deny
    // ═══════════════════════════════════════════

    /// @dev FIXED. The country branch used to return `(level, reason)` — the user's REAL level —
    ///      instead of `AccessLevel.DENIED`. The hook only compares levels and discards `reason`
    ///      on success, so the flag changed nothing unless minSwapLevel was already >= ACCREDITED,
    ///      in which case it was redundant. An EU-only pool with requireCountry=true and
    ///      minSwap=RETAIL admitted users with no country attestation. It now denies them.
    function test_Finding2_RegionalPolicy_RequireCountryAttestationDenies() public {
        vm.prank(owner);
        regionalPolicy.setRegionConfig(
            regionalKey.toId(),
            true, // requireCountryAttestation
            false,
            ILexifiPolicy.AccessLevel.RETAIL,
            ILexifiPolicy.AccessLevel.RETAIL
        );

        // retailUser is tier 1 (account only, no country attestation).
        (ILexifiPolicy.AccessLevel level, string memory reason) =
            regionalPolicy.checkAccess(regionalKey.toId(), retailUser, OP_SWAP, 0);
        assertEq(reason, "Country verification required for this pool");
        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.DENIED), "must report DENIED");

        // The enforcement path must now actually stop them.
        assertFalse(_allowed(regionalPoolId, retailUser, OP_SWAP), "country requirement enforced");
        assertFalse(_allowed(regionalPoolId, retailUser, OP_LP), "and on the LP path too");

        // accreditedUser is tier 2 — country attested — and still gets through.
        assertTrue(_allowed(regionalPoolId, accreditedUser, OP_SWAP), "attested user allowed");
    }

    /// @dev The sibling branch had the identical defect and the identical fix.
    function test_Finding2_RegionalPolicy_RequireAccountAttestationDenies() public {
        vm.prank(owner);
        regionalPolicy.setRegionConfig(
            regionalKey.toId(),
            false,
            true, // requireAccountAttestation
            ILexifiPolicy.AccessLevel.DENIED,
            ILexifiPolicy.AccessLevel.DENIED
        );

        address tierZeroButVerified = address(0x3333);
        vm.prank(owner);
        provider.setUser(tierZeroButVerified, 0, true); // verified, but tier 0

        (ILexifiPolicy.AccessLevel level, string memory reason) =
            regionalPolicy.checkAccess(regionalKey.toId(), tierZeroButVerified, OP_SWAP, 0);
        assertEq(reason, "Account verification required");
        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.DENIED), "must report DENIED");
    }

    // ═══════════════════════════════════════════
    //  FINDING 3 — InstitutionalPolicy: N-of-M is not enforced
    // ═══════════════════════════════════════════

    /// @dev FIXED. `highestTier` is only updated for providers that PASSED, so a user cleared by
    ///      even one provider came back at >= minimumTier. The policy returned that level with an
    ///      "Insufficient institutional verifications" reason — and the level comparison passed.
    ///      The N-of-M quorum, the headline feature of this policy, gated nothing. It now denies.
    function test_Finding3_InstitutionalPolicy_QuorumEnforced() public {
        address[] memory providers = new address[](3);
        providers[0] = address(provider);
        providers[1] = address(provider2);
        providers[2] = address(provider3);

        vm.prank(owner);
        institutionalPolicy.setInstitutionalConfig(
            institutionalKey.toId(), providers, 2, ILexifiPolicy.AccessLevel.ACCREDITED
        );

        // Only provider1 verifies this user. 1 of 3, quorum is 2 of 3.
        assertEq(provider2.userTiers(accreditedUser), 0);
        assertEq(provider3.userTiers(accreditedUser), 0);

        (ILexifiPolicy.AccessLevel level, string memory reason) =
            institutionalPolicy.checkAccess(institutionalKey.toId(), accreditedUser, OP_SWAP, 0);
        assertEq(reason, "Insufficient institutional verifications");
        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.DENIED), "must report DENIED");

        assertFalse(
            _allowed(institutionalPoolId, accreditedUser, OP_SWAP), "quorum shortfall enforced"
        );
        assertFalse(
            _allowed(institutionalPoolId, accreditedUser, OP_LP), "and on the LP path too"
        );
    }

    /// @dev Reaching quorum still admits the user — the fix denies short of N, nothing more.
    function test_Finding3_InstitutionalPolicy_QuorumMetStillAllowed() public {
        address[] memory providers = new address[](3);
        providers[0] = address(provider);
        providers[1] = address(provider2);
        providers[2] = address(provider3);

        vm.startPrank(owner);
        institutionalPolicy.setInstitutionalConfig(
            institutionalKey.toId(), providers, 2, ILexifiPolicy.AccessLevel.ACCREDITED
        );
        provider2.setUser(accreditedUser, 2, true); // second provider clears them: 2 of 3
        vm.stopPrank();

        (ILexifiPolicy.AccessLevel level, string memory reason) =
            institutionalPolicy.checkAccess(institutionalKey.toId(), accreditedUser, OP_SWAP, 0);
        assertEq(reason, "");
        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.ACCREDITED));

        assertTrue(_allowed(institutionalPoolId, accreditedUser, OP_SWAP), "quorum met, allowed");
    }

    /// @dev Positive control: a user no provider clears is still correctly denied, because
    ///      highestTier stays 0. The bug is confined to partial-quorum cases.
    function test_Finding3_InstitutionalPolicy_ZeroProvidersStillDenied() public {
        address[] memory providers = new address[](3);
        providers[0] = address(provider);
        providers[1] = address(provider2);
        providers[2] = address(provider3);

        vm.prank(owner);
        institutionalPolicy.setInstitutionalConfig(
            institutionalKey.toId(), providers, 2, ILexifiPolicy.AccessLevel.ACCREDITED
        );

        assertFalse(_allowed(institutionalPoolId, retailUser, OP_SWAP));
    }

    /// @dev InstitutionalPolicy is NOT vulnerable to the swap/LP asymmetry: its `minimumLevel`
    ///      ignores `operation`, so the two answers can never diverge. (The flip side is that
    ///      it cannot express different swap and LP requirements at all.)
    function test_InstitutionalPolicy_HasNoSwapLpAsymmetry() public {
        address[] memory providers = new address[](1);
        providers[0] = address(provider);

        vm.prank(owner);
        institutionalPolicy.setInstitutionalConfig(
            institutionalKey.toId(), providers, 1, ILexifiPolicy.AccessLevel.ACCREDITED
        );

        assertEq(
            _allowed(institutionalPoolId, retailUser, OP_SWAP),
            _allowed(institutionalPoolId, retailUser, OP_LP)
        );
        assertEq(
            _allowed(institutionalPoolId, accreditedUser, OP_SWAP),
            _allowed(institutionalPoolId, accreditedUser, OP_LP)
        );
    }

    // ═══════════════════════════════════════════
    //  MITIGATION — the checker already contains Finding 1
    // ═══════════════════════════════════════════

    /// @dev `liquidityRequiresSwap` still matters after the three fixes, because ThresholdPolicy
    ///      has an asymmetry that config validation cannot remove: it gates swaps on trade SIZE
    ///      but gates LPs on tier alone, so a RETAIL address denied a large swap still clears the
    ///      raw LP check. That is inherent to the policy, not a misconfiguration, so the checker
    ///      flag remains the mitigation on the Permissioned Pools path. Pools using LexifiHook
    ///      directly are still exposed to it — see the note in DEPLOYMENT-RUNBOOK.md.
    function test_Mitigation_AllowlistCheckerClosesThresholdAsymmetry() public {
        vm.startPrank(owner);

        // Swaps above enhancedLimit demand ACCREDITED; LPs demand only RETAIL.
        thresholdPolicy.setPoolConfig(
            thresholdKey.toId(),
            1, // noKycLimit
            100, // enhancedLimit
            ILexifiPolicy.AccessLevel.RETAIL, // lpMinimum
            ILexifiPolicy.AccessLevel.RETAIL // swapMinimum
        );

        // The asymmetry itself, straight through the enforcement path.
        assertFalse(_allowedAt(thresholdPoolId, retailUser, OP_SWAP, 1000), "large swap denied");
        assertTrue(_allowedAt(thresholdPoolId, retailUser, OP_LP, 1000), "raw LP check clears");

        address token = address(0xA55E7);
        LexifiAllowlistChecker checker =
            new LexifiAllowlistChecker(ILexifiCompliance(address(complianceAdapter)), owner);

        // Coupled (default): LIQUIDITY_ALLOWED is withheld because SWAP_ALLOWED was denied.
        checker.bindToken(token, thresholdPoolId, 1000, true);
        assertEq(uint16(PermissionFlag.unwrap(checker.checkAllowlist(retailUser, token))), 0x0000);

        // Decoupled: the policy's raw answer comes through, asymmetry and all.
        checker.bindToken(token, thresholdPoolId, 1000, false);
        assertEq(uint16(PermissionFlag.unwrap(checker.checkAllowlist(retailUser, token))), 0x0002);
        vm.stopPrank();
    }
}
