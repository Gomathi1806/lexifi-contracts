// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {InstitutionalPolicy} from "../src/policies/InstitutionalPolicy.sol";
import {ILexifiPolicy} from "../src/interfaces/ILexifiPolicy.sol";
import {MockVerificationProvider} from "./mocks/MockVerificationProvider.sol";

contract InstitutionalPolicyTest is Test {
    using PoolIdLibrary for PoolKey;

    InstitutionalPolicy public policy;
    MockVerificationProvider public provider1;
    MockVerificationProvider public provider2;
    MockVerificationProvider public provider3;

    address public admin = address(0xAD);
    address public fullyVerified = address(0x1);
    address public partiallyVerified = address(0x2);
    address public unverified = address(0x3);

    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        // Deploy 3 providers (simulating Coinbase + Worldcoin + ZK-proof)
        provider1 = new MockVerificationProvider();
        provider2 = new MockVerificationProvider();
        provider3 = new MockVerificationProvider();

        policy = new InstitutionalPolicy(admin);

        // fullyVerified: passes all 3 providers at tier 3
        provider1.setUser(fullyVerified, 3, true);
        provider2.setUser(fullyVerified, 3, true);
        provider3.setUser(fullyVerified, 3, true);

        // partiallyVerified: passes only 1 provider
        provider1.setUser(partiallyVerified, 2, true);
        provider2.setUser(partiallyVerified, 0, false);
        provider3.setUser(partiallyVerified, 0, false);

        // unverified: passes none
        provider1.setUser(unverified, 0, false);
        provider2.setUser(unverified, 0, false);
        provider3.setUser(unverified, 0, false);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x100)),
            currency1: Currency.wrap(address(0x200)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();

        // Configure: require 2-of-3 providers at ACCREDITED minimum
        address[] memory providers = new address[](3);
        providers[0] = address(provider1);
        providers[1] = address(provider2);
        providers[2] = address(provider3);

        vm.prank(admin);
        policy.setInstitutionalConfig(
            poolId,
            providers,
            2,  // minimumProviders: 2 of 3
            ILexifiPolicy.AccessLevel.ACCREDITED
        );
    }

    function test_PolicyName() public view {
        assertEq(policy.policyName(), "Lexifi Institutional Policy");
    }

    function test_FullyVerified_Passes() public view {
        (ILexifiPolicy.AccessLevel level, string memory reason) =
            policy.checkAccess(poolId, fullyVerified, 0, 0);

        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.INSTITUTIONAL));
        assertEq(bytes(reason).length, 0);
    }

    /// @dev This test used to assert only `bytes(reason).length > 0`, which is true whether or
    ///      not the user is actually denied — the hook discards `reason` whenever the level
    ///      comparison passes. It therefore reported green while the N-of-M quorum gated nothing
    ///      (audit Finding 3). It now asserts the level the enforcement path actually compares.
    function test_PartiallyVerified_OnlyOneProvider_Denied() public view {
        // Only 1 of 3 passed, need 2 of 3
        (ILexifiPolicy.AccessLevel level, string memory reason) =
            policy.checkAccess(poolId, partiallyVerified, 0, 0);

        assertEq(reason, "Insufficient institutional verifications");
        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.DENIED), "must be DENIED");
        // The gate the hook applies: level >= minimumLevel(operation).
        assertLt(uint8(level), uint8(policy.minimumLevel(poolId, 0)), "must fail the real gate");
    }

    function test_Unverified_Denied() public view {
        (ILexifiPolicy.AccessLevel level, string memory reason) =
            policy.checkAccess(poolId, unverified, 0, 0);

        assertEq(uint8(level), 0);
        assertTrue(bytes(reason).length > 0);
    }

    function test_MinimumLevel() public view {
        ILexifiPolicy.AccessLevel min = policy.minimumLevel(poolId, 0);
        assertEq(uint8(min), uint8(ILexifiPolicy.AccessLevel.ACCREDITED));
    }

    function test_UnconfiguredPool_OpenAccess() public view {
        PoolKey memory otherKey = PoolKey({
            currency0: Currency.wrap(address(0x300)),
            currency1: Currency.wrap(address(0x400)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        (ILexifiPolicy.AccessLevel level, ) =
            policy.checkAccess(otherKey.toId(), unverified, 0, 0);

        assertEq(uint8(level), uint8(ILexifiPolicy.AccessLevel.INSTITUTIONAL));
    }

    function test_GetConfig() public view {
        (address[] memory providers, uint256 minProviders, ILexifiPolicy.AccessLevel minTier, bool active) =
            policy.getConfig(poolId);

        assertEq(providers.length, 3);
        assertEq(minProviders, 2);
        assertEq(uint8(minTier), uint8(ILexifiPolicy.AccessLevel.ACCREDITED));
        assertTrue(active);
    }

    function test_TooFewProviders_Reverts() public {
        address[] memory empty = new address[](0);

        vm.prank(admin);
        vm.expectRevert(InstitutionalPolicy.TooFewProviders.selector);
        policy.setInstitutionalConfig(
            poolId,
            empty,
            1,
            ILexifiPolicy.AccessLevel.RETAIL
        );
    }

    function test_MinProvidersExceedsTotal_Reverts() public {
        address[] memory providers = new address[](1);
        providers[0] = address(provider1);

        PoolKey memory newKey = PoolKey({
            currency0: Currency.wrap(address(0x500)),
            currency1: Currency.wrap(address(0x600)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.prank(admin);
        vm.expectRevert(InstitutionalPolicy.TooFewProviders.selector);
        policy.setInstitutionalConfig(
            newKey.toId(),
            providers,
            5,  // more than providers.length
            ILexifiPolicy.AccessLevel.RETAIL
        );
    }
}
