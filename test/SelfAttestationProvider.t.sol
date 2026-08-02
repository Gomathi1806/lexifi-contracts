// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {SelfAttestationProvider} from "../src/policies/SelfAttestationProvider.sol";
import {IVerificationProvider} from "../src/interfaces/IVerificationProvider.sol";
import {CoinbaseEASProvider} from "../src/policies/CoinbaseEASProvider.sol";
import {InstitutionalPolicy} from "../src/policies/InstitutionalPolicy.sol";
import {ILexifiPolicy} from "../src/interfaces/ILexifiPolicy.sol";
import {MockVerificationProvider} from "./mocks/MockVerificationProvider.sol";

contract SelfAttestationProviderTest is Test {
    using PoolIdLibrary for PoolKey;

    SelfAttestationProvider public provider;
    address public owner = address(0xAD);
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public user3 = address(0x3);
    address public nobody = address(0x99);

    function setUp() public {
        vm.prank(owner);
        provider = new SelfAttestationProvider(owner, "Lexifi Operator KYC");
    }

    // ═══════════════════════════════════════════
    //  BASIC PROVIDER INFO
    // ═══════════════════════════════════════════

    function test_ProviderName() public view {
        assertEq(provider.providerName(), "Lexifi Operator KYC");
    }

    function test_ProviderId() public view {
        bytes32 expected = keccak256(abi.encodePacked("self-attestation-", "Lexifi Operator KYC"));
        assertEq(provider.providerId(), expected);
    }

    function test_SupportsKYC() public view {
        assertTrue(provider.supportsType(keccak256("KYC")));
        assertTrue(provider.supportsType(keccak256("ACCREDITED")));
        assertFalse(provider.supportsType(keccak256("COUNTRY")));
    }

    // ═══════════════════════════════════════════
    //  ATTESTATION
    // ═══════════════════════════════════════════

    function test_Attest_SingleUser() public {
        vm.prank(owner);
        provider.attest(user1, 2, 0);

        IVerificationProvider.VerificationResult memory r = provider.verify(user1);
        assertTrue(r.verified);
        assertEq(r.tier, 2);
        assertEq(r.expiry, 0);
        assertEq(r.providerName, "Lexifi Operator KYC");
        assertTrue(r.attestationId != bytes32(0));
    }

    function test_Attest_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit SelfAttestationProvider.UserAttested(user1, 3, 0);

        vm.prank(owner);
        provider.attest(user1, 3, 0);
    }

    function test_Attest_UpdatesTier() public {
        vm.startPrank(owner);
        provider.attest(user1, 1, 0);
        provider.attest(user1, 3, 0);
        vm.stopPrank();

        IVerificationProvider.VerificationResult memory r = provider.verify(user1);
        assertEq(r.tier, 3);
    }

    function test_Attest_OnlyOwner() public {
        vm.prank(nobody);
        vm.expectRevert(SelfAttestationProvider.Unauthorized.selector);
        provider.attest(user1, 1, 0);
    }

    function test_Attest_ZeroAddress_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(SelfAttestationProvider.ZeroAddress.selector);
        provider.attest(address(0), 1, 0);
    }

    // ═══════════════════════════════════════════
    //  BATCH ATTESTATION
    // ═══════════════════════════════════════════

    function test_AttestBatch() public {
        address[] memory users = new address[](3);
        uint256[] memory tiers = new uint256[](3);
        uint256[] memory expiries = new uint256[](3);

        users[0] = user1; tiers[0] = 1; expiries[0] = 0;
        users[1] = user2; tiers[1] = 2; expiries[1] = 0;
        users[2] = user3; tiers[2] = 3; expiries[2] = 0;

        vm.prank(owner);
        provider.attestBatch(users, tiers, expiries);

        assertEq(provider.verify(user1).tier, 1);
        assertEq(provider.verify(user2).tier, 2);
        assertEq(provider.verify(user3).tier, 3);
    }

    function test_AttestBatch_OnlyOwner() public {
        address[] memory users = new address[](1);
        uint256[] memory tiers = new uint256[](1);
        uint256[] memory expiries = new uint256[](1);
        users[0] = user1; tiers[0] = 1; expiries[0] = 0;

        vm.prank(nobody);
        vm.expectRevert(SelfAttestationProvider.Unauthorized.selector);
        provider.attestBatch(users, tiers, expiries);
    }

    // ═══════════════════════════════════════════
    //  REVOCATION
    // ═══════════════════════════════════════════

    function test_Revoke() public {
        vm.startPrank(owner);
        provider.attest(user1, 2, 0);
        provider.revoke(user1);
        vm.stopPrank();

        IVerificationProvider.VerificationResult memory r = provider.verify(user1);
        assertFalse(r.verified);
        assertEq(r.tier, 0);
    }

    function test_Revoke_EmitsEvent() public {
        vm.startPrank(owner);
        provider.attest(user1, 2, 0);

        vm.expectEmit(true, false, false, false);
        emit SelfAttestationProvider.UserRevoked(user1);
        provider.revoke(user1);
        vm.stopPrank();
    }

    function test_Revoke_OnlyOwner() public {
        vm.prank(owner);
        provider.attest(user1, 2, 0);

        vm.prank(nobody);
        vm.expectRevert(SelfAttestationProvider.Unauthorized.selector);
        provider.revoke(user1);
    }

    // ═══════════════════════════════════════════
    //  EXPIRY
    // ═══════════════════════════════════════════

    function test_Verify_ExpiredAttestation() public {
        vm.prank(owner);
        provider.attest(user1, 2, block.timestamp + 1 hours);

        // Still valid
        assertTrue(provider.verify(user1).verified);

        // Fast-forward past expiry
        vm.warp(block.timestamp + 2 hours);
        IVerificationProvider.VerificationResult memory r = provider.verify(user1);
        assertFalse(r.verified);
    }

    function test_Verify_NoExpiry() public {
        vm.prank(owner);
        provider.attest(user1, 3, 0);

        vm.warp(block.timestamp + 365 days);
        assertTrue(provider.verify(user1).verified);
    }

    // ═══════════════════════════════════════════
    //  UNATTESTED USER
    // ═══════════════════════════════════════════

    function test_Verify_UnattestedUser() public view {
        IVerificationProvider.VerificationResult memory r = provider.verify(nobody);
        assertFalse(r.verified);
        assertEq(r.tier, 0);
        assertEq(r.providerName, "Lexifi Operator KYC");
    }

    // ═══════════════════════════════════════════
    //  OWNERSHIP
    // ═══════════════════════════════════════════

    function test_TransferOwnership() public {
        vm.prank(owner);
        provider.transferOwnership(user1);

        // Old owner can't attest anymore
        vm.prank(owner);
        vm.expectRevert(SelfAttestationProvider.Unauthorized.selector);
        provider.attest(user2, 1, 0);

        // New owner can
        vm.prank(user1);
        provider.attest(user2, 1, 0);
        assertTrue(provider.verify(user2).verified);
    }

    function test_TransferOwnership_ZeroAddress_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(SelfAttestationProvider.ZeroAddress.selector);
        provider.transferOwnership(address(0));
    }

    function test_Constructor_ZeroOwner_Reverts() public {
        vm.expectRevert(SelfAttestationProvider.ZeroAddress.selector);
        new SelfAttestationProvider(address(0), "test");
    }

    // ═══════════════════════════════════════════
    //  MULTI-PROVIDER INTEGRATION
    // ═══════════════════════════════════════════

    function test_InstitutionalPolicy_TwoProviders() public {
        // Provider 1: mock Coinbase (tier 3 for user1)
        MockVerificationProvider coinbase = new MockVerificationProvider();
        coinbase.setUser(user1, 3, true);

        // Provider 2: SelfAttestation (tier 2 for user1)
        SelfAttestationProvider selfProvider = new SelfAttestationProvider(owner, "DEX Operator");
        vm.prank(owner);
        selfProvider.attest(user1, 2, 0);

        // InstitutionalPolicy: require 2-of-2 at ACCREDITED
        InstitutionalPolicy instPolicy = new InstitutionalPolicy(owner);

        PoolKey memory pk = PoolKey({
            currency0: Currency.wrap(address(0x100)),
            currency1: Currency.wrap(address(0x200)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        address[] memory providers = new address[](2);
        providers[0] = address(coinbase);
        providers[1] = address(selfProvider);

        vm.prank(owner);
        instPolicy.setInstitutionalConfig(
            pk.toId(),
            providers,
            2,
            ILexifiPolicy.AccessLevel.ACCREDITED
        );

        // user1 passes both → allowed
        (ILexifiPolicy.AccessLevel level, string memory reason) =
            instPolicy.checkAccess(pk.toId(), user1, 0, 0);
        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.INSTITUTIONAL));
        assertEq(bytes(reason).length, 0);

        // user2 (not attested in self-provider) → denied
        coinbase.setUser(user2, 3, true);
        (ILexifiPolicy.AccessLevel level2, string memory reason2) =
            instPolicy.checkAccess(pk.toId(), user2, 0, 0);
        assertTrue(bytes(reason2).length > 0);
    }

    function test_InstitutionalPolicy_RevokeBreaksAccess() public {
        MockVerificationProvider coinbase = new MockVerificationProvider();
        coinbase.setUser(user1, 3, true);

        SelfAttestationProvider selfProvider = new SelfAttestationProvider(owner, "DEX Operator");
        vm.prank(owner);
        selfProvider.attest(user1, 3, 0);

        InstitutionalPolicy instPolicy = new InstitutionalPolicy(owner);

        PoolKey memory pk = PoolKey({
            currency0: Currency.wrap(address(0x100)),
            currency1: Currency.wrap(address(0x200)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        address[] memory providers = new address[](2);
        providers[0] = address(coinbase);
        providers[1] = address(selfProvider);

        vm.prank(owner);
        instPolicy.setInstitutionalConfig(
            pk.toId(), providers, 2, ILexifiPolicy.AccessLevel.ACCREDITED
        );

        // Passes initially
        (ILexifiPolicy.AccessLevel level, string memory reason) =
            instPolicy.checkAccess(pk.toId(), user1, 0, 0);
        assertEq(bytes(reason).length, 0);

        // Revoke from self-attestation → now fails 2-of-2
        vm.prank(owner);
        selfProvider.revoke(user1);

        (, string memory reason2) = instPolicy.checkAccess(pk.toId(), user1, 0, 0);
        assertTrue(bytes(reason2).length > 0);
    }
}
