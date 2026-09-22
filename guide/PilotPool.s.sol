// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LexifiHook} from "../src/LexifiHook.sol";
import {LexifiPolicyConfig} from "../src/LexifiPolicyConfig.sol";
import {RegionalPolicyV3} from "../src/policies/RegionalPolicyV3.sol";
import {ThresholdPolicy} from "../src/policies/ThresholdPolicy.sol";
import {ILexifiPolicy} from "../src/interfaces/ILexifiPolicy.sol";

/// @title PilotPool — create a Base pool that enforces Lexifi compliance rules.
/// @notice For issuers and venues running their own pool. Everything happens from YOUR address:
///         you create the pool, you become its admin on the hook, and only you can change its
///         rules afterwards. Lexifi cannot change them.
///
/// Usage: copy guide/env.example to .env, fill it in, then
///     forge script guide/PilotPool.s.sol --rpc-url $RPC_URL --broadcast
contract PilotPoolScript is Script {
    using PoolIdLibrary for PoolKey;

    // Base mainnet (chainId 8453)
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant HOOK = 0xfE92DE69d2dDdcAc2f864C4cF84e8aD5E17D2880;
    address constant POLICY_CONFIG = 0x9E005c201AEe5Db3c67b3658Cc18723dfDEe42E1;
    address constant REGIONAL_POLICY = 0x5309C741094e8901f9D2Ad1f31DC560006542a82;
    address constant THRESHOLD_POLICY = 0x75f4913F53B694fDda95E49456D163Ca7AEf4199;

    function run() external {
        // No private key required. Leave PRIVATE_KEY unset and sign with a hardware wallet
        // (--ledger) or an encrypted keystore (--account <name>); the signer is then --sender.
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address admin = pk != 0 ? vm.addr(pk) : msg.sender;

        // --- pool identity ---
        // currency0 MUST sort below currency1. Native ETH is address(0).
        address currency0 = vm.envAddress("CURRENCY0");
        address currency1 = vm.envAddress("CURRENCY1");
        require(currency0 < currency1, "CURRENCY0 must sort below CURRENCY1");

        uint24 fee = uint24(vm.envUint("FEE")); // e.g. 3000 = 0.30%
        int24 tickSpacing = int24(int256(vm.envInt("TICK_SPACING"))); // e.g. 60
        uint160 sqrtPriceX96 = uint160(vm.envUint("SQRT_PRICE_X96"));

        // "regional" (jurisdiction rules) or "threshold" (rules by trade size)
        string memory policyKind = vm.envString("POLICY");
        bool isRegional = keccak256(bytes(policyKind)) == keccak256("regional");
        address policy = isRegional ? REGIONAL_POLICY : THRESHOLD_POLICY;

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(HOOK)
        });
        PoolId poolId = key.toId();

        console.log("=== LEXIFI PILOT POOL ===");
        console.log("Pool admin (you):", admin);
        console.log("Policy:", policyKind, policy);
        console.log("Pool id:");
        console.logBytes32(PoolId.unwrap(poolId));

        if (pk != 0) {
            vm.startBroadcast(pk);
        } else {
            vm.startBroadcast();
        }

        // --- 1. create the pool, with LexifiHook attached ---
        // Skipped when the pool already exists: initialize reverts on a second call.
        if (vm.envOr("SKIP_INITIALIZE", false)) {
            console.log("[1] initialize skipped (SKIP_INITIALIZE=true)");
        } else {
            int24 tick = IPoolManager(POOL_MANAGER).initialize(key, sqrtPriceX96);
            console.log("[1] pool created at tick:", tick);
        }

        // --- 2. claim the pool on the hook: this makes YOU its admin ---
        // Emits PoolPolicySet(poolId, policy, name, version, poolCreator = you).
        LexifiHook(HOOK).setPoolPolicy(key, policy);
        console.log("[2] setPoolPolicy done. You are now this pool's admin on the hook.");

        // --- 3. write the pool's rules ---
        if (isRegional) {
            // Jurisdiction rules, read from on-chain attestations.
            bool requireCountry = vm.envOr("REQUIRE_COUNTRY", true);
            bool requireAccount = vm.envOr("REQUIRE_ACCOUNT", false);
            ILexifiPolicy.AccessLevel minSwap =
                ILexifiPolicy.AccessLevel(uint8(vm.envOr("MIN_SWAP_LEVEL", uint256(2))));
            ILexifiPolicy.AccessLevel minLp =
                ILexifiPolicy.AccessLevel(uint8(vm.envOr("MIN_LP_LEVEL", uint256(2))));

            bytes memory cfg = RegionalPolicyV3(REGIONAL_POLICY).encodeConfig(
                requireCountry, requireAccount, minSwap, minLp
            );
            LexifiPolicyConfig(POLICY_CONFIG).setConfig(
                RegionalPolicyV3(REGIONAL_POLICY).CONFIG_FAMILY(), poolId, cfg
            );
            console.log("[3] regional config written. requireCountry:", requireCountry);
            console.log("    minSwapLevel:", uint8(minSwap), "minLpLevel:", uint8(minLp));
        } else {
            // Rules by trade size: small trades open, larger ones need verification.
            uint256 noKycLimit = vm.envOr("NO_KYC_LIMIT", uint256(1e14));
            uint256 enhancedLimit = vm.envOr("ENHANCED_LIMIT", uint256(1e18));
            ILexifiPolicy.AccessLevel lpMin =
                ILexifiPolicy.AccessLevel(uint8(vm.envOr("MIN_LP_LEVEL", uint256(0))));
            ILexifiPolicy.AccessLevel swapMin =
                ILexifiPolicy.AccessLevel(uint8(vm.envOr("MIN_SWAP_LEVEL", uint256(1))));

            ThresholdPolicy(THRESHOLD_POLICY).setPoolConfig(
                poolId, noKycLimit, enhancedLimit, lpMin, swapMin
            );
            console.log("[3] threshold config written. noKycLimit:", noKycLimit);
            console.log("    enhancedLimit:", enhancedLimit, "swapMinimum:", uint8(swapMin));
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== DONE. Verify it yourself: ===");
        console.log("cast call %s 'poolAdmin(bytes32)(address)' <poolId> --rpc-url <rpc>", HOOK);
        console.log("cast call %s 'poolPolicy(bytes32)(address)' <poolId> --rpc-url <rpc>", HOOK);
        console.log("Your address should come back as the admin. Add liquidity next.");
    }
}
