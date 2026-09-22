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

/// @title SafeBatch — produce a Safe Transaction Builder file for a compliant pool.
/// @notice For issuers whose treasury lives in a Safe. This writes the same three calls as
///         PilotPool.s.sol into `guide/safe-batch.json`, which you upload to the Safe's
///         Transaction Builder app and sign with your normal signers.
///
///         No private key, no keystore and no RPC: this only encodes calldata.
///         The pool admin recorded on the hook will be the Safe itself.
///
/// Usage: fill in .env (see guide/env.example), then
///     forge script guide/SafeBatch.s.sol
contract SafeBatchScript is Script {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant HOOK = 0xfE92DE69d2dDdcAc2f864C4cF84e8aD5E17D2880;
    address constant POLICY_CONFIG = 0x9E005c201AEe5Db3c67b3658Cc18723dfDEe42E1;
    address constant REGIONAL_POLICY = 0x5309C741094e8901f9D2Ad1f31DC560006542a82;
    address constant THRESHOLD_POLICY = 0x75f4913F53B694fDda95E49456D163Ca7AEf4199;

    bytes32 constant REGIONAL_FAMILY = keccak256("lexifi.policy.regional");

    function run() external {
        address currency0 = vm.envAddress("CURRENCY0");
        address currency1 = vm.envAddress("CURRENCY1");
        require(currency0 < currency1, "CURRENCY0 must sort below CURRENCY1");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: uint24(vm.envUint("FEE")),
            tickSpacing: int24(int256(vm.envInt("TICK_SPACING"))),
            hooks: IHooks(HOOK)
        });
        PoolId poolId = key.toId();
        uint160 sqrtPriceX96 = uint160(vm.envUint("SQRT_PRICE_X96"));

        bool isRegional =
            keccak256(bytes(vm.envString("POLICY"))) == keccak256("regional");
        address policy = isRegional ? REGIONAL_POLICY : THRESHOLD_POLICY;

        // --- the three calls, in order ---
        bytes memory call1 = abi.encodeCall(IPoolManager.initialize, (key, sqrtPriceX96));
        bytes memory call2 = abi.encodeCall(LexifiHook.setPoolPolicy, (key, policy));

        address target3;
        bytes memory call3;
        if (isRegional) {
            RegionalPolicyV3.RegionConfig memory cfg = RegionalPolicyV3.RegionConfig({
                requireCountryAttestation: vm.envOr("REQUIRE_COUNTRY", true),
                requireAccountAttestation: vm.envOr("REQUIRE_ACCOUNT", false),
                minimumSwapLevel: ILexifiPolicy.AccessLevel(
                    uint8(vm.envOr("MIN_SWAP_LEVEL", uint256(2)))
                ),
                minimumLpLevel: ILexifiPolicy.AccessLevel(
                    uint8(vm.envOr("MIN_LP_LEVEL", uint256(2)))
                ),
                active: true
            });
            target3 = POLICY_CONFIG;
            call3 = abi.encodeCall(
                LexifiPolicyConfig.setConfig, (REGIONAL_FAMILY, poolId, abi.encode(cfg))
            );
        } else {
            target3 = THRESHOLD_POLICY;
            call3 = abi.encodeCall(
                ThresholdPolicy.setPoolConfig,
                (
                    poolId,
                    vm.envOr("NO_KYC_LIMIT", uint256(1e14)),
                    vm.envOr("ENHANCED_LIMIT", uint256(1e18)),
                    ILexifiPolicy.AccessLevel(uint8(vm.envOr("MIN_LP_LEVEL", uint256(0)))),
                    ILexifiPolicy.AccessLevel(uint8(vm.envOr("MIN_SWAP_LEVEL", uint256(1))))
                )
            );
        }

        string memory json = string.concat(
            '{\n  "version": "1.0",\n  "chainId": "8453",\n  "createdAt": ',
            vm.toString(vm.unixTime()),
            ',\n  "meta": {\n    "name": "Lexifi compliant pool",\n',
            '    "description": "Create the pool, take pool admin, write its rules",\n',
            '    "txBuilderVersion": "1.16.5"\n  },\n  "transactions": [\n',
            _tx(POOL_MANAGER, call1),
            ",\n",
            _tx(HOOK, call2),
            ",\n",
            _tx(target3, call3),
            "\n  ]\n}\n"
        );

        string memory out = vm.envOr("SAFE_BATCH_OUT", string("guide/safe-batch.json"));
        vm.writeFile(out, json);

        console.log("=== SAFE BATCH WRITTEN ===");
        console.log("File:", out);
        console.log("Pool id:");
        console.logBytes32(PoolId.unwrap(poolId));
        console.log("Policy:", policy);
        console.log("");
        console.log("Upload it in your Safe: Apps > Transaction Builder > Load batch.");
        console.log("The Safe becomes the pool admin, so only your signers can change the rules.");
    }

    function _tx(address to, bytes memory data) private pure returns (string memory) {
        return string.concat(
            '    {\n      "to": "',
            vm.toString(to),
            '",\n      "value": "0",\n      "data": "',
            vm.toString(data),
            '",\n      "contractMethod": null,\n      "contractInputsValues": null\n    }'
        );
    }
}
