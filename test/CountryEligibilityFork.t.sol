// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

import {LexifiPolicyConfigV2, IPoolAdminSource} from "../src/LexifiPolicyConfigV2.sol";
import {ILexifiPolicy} from "../src/interfaces/ILexifiPolicy.sol";
import {CoinbaseEASProvider} from "../src/policies/CoinbaseEASProvider.sol";
import {CountryEligibilityPolicy} from "../src/policies/CountryEligibilityPolicy.sol";

/// @dev Reads real Coinbase attestations through the live CoinbaseEASProvider on Base. Skipped
///      unless RUN_FORK_TESTS=true. Wallet samples come from the environment so no third party's
///      address and country are recorded in this repo:
///        FORK_US_WALLETS      comma-separated wallets attested to the US
///        FORK_NON_US_WALLETS  comma-separated wallets attested elsewhere
contract CountryEligibilityForkTest is Test, IPoolAdminSource {
    address constant LIVE_PROVIDER = 0xb5DEC225A104A276671A765aba3890EC88A2ca27;
    PoolId constant POOL = PoolId.wrap(keccak256("fork-test-pool"));

    CountryEligibilityPolicy policy;
    CoinbaseEASProvider provider;

    function poolAdmin(PoolId) external view returns (address) {
        return address(this);
    }

    function _setUpFork() internal returns (bool) {
        if (!vm.envOr("RUN_FORK_TESTS", false)) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork("base");
        LexifiPolicyConfigV2 registry = new LexifiPolicyConfigV2(IPoolAdminSource(address(this)));
        policy = new CountryEligibilityPolicy(LIVE_PROVIDER, address(registry));
        provider = CoinbaseEASProvider(LIVE_PROVIDER);

        bytes memory config = policy.encodeConfig(
            ILexifiPolicy.AccessLevel.RETAIL, ILexifiPolicy.AccessLevel.RETAIL, false, new bytes2[](0)
        );
        registry.setConfig(policy.CONFIG_FAMILY(), POOL, config);
        return true;
    }

    function _passes(address who, uint8 op) internal view returns (bool) {
        (ILexifiPolicy.AccessLevel level,) = policy.checkAccess(POOL, who, op, 1e18);
        return uint8(level) >= uint8(policy.minimumLevel(POOL, op));
    }

    function test_Fork_UsWallets_Denied() public {
        if (!_setUpFork()) return;
        address[] memory wallets = vm.envAddress("FORK_US_WALLETS", ",");
        uint256 verified;
        for (uint256 i = 0; i < wallets.length; i++) {
            assertFalse(_passes(wallets[i], 0), "US swap");
            assertFalse(_passes(wallets[i], 1), "US LP");
            if (provider.verify(wallets[i]).tier >= 2) verified++;
        }
        // The denial must come from the country value, not from a missing verification.
        assertGt(verified, 0, "sample holds no fully verified US wallet");
    }

    function test_Fork_NonUsWallets_Pass() public {
        if (!_setUpFork()) return;
        address[] memory wallets = vm.envAddress("FORK_NON_US_WALLETS", ",");
        uint256 checked;
        for (uint256 i = 0; i < wallets.length; i++) {
            if (provider.verify(wallets[i]).tier < 2) continue;
            assertTrue(_passes(wallets[i], 0), "non-US swap");
            checked++;
        }
        assertGt(checked, 0, "sample holds no fully verified non-US wallet");
    }

    function test_Fork_UnverifiedWallet_Denied() public {
        if (!_setUpFork()) return;
        assertFalse(_passes(makeAddr("nobody"), 0));
    }
}
