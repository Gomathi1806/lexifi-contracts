// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";
import {LexifiHook} from "../src/LexifiHook.sol";
import {ThresholdPolicy} from "../src/policies/ThresholdPolicy.sol";
import {ILexifiPolicy} from "../src/interfaces/ILexifiPolicy.sol";
import {Phase1Prover} from "./Phase1Prover.sol";

contract Phase1Script is Script {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant HOOK = 0xfE92DE69d2dDdcAc2f864C4cF84e8aD5E17D2880;
    address constant THRESHOLD_POLICY = 0x75f4913F53B694fDda95E49456D163Ca7AEf4199;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2^96 = price 1:1
    int24 constant TICK_LOWER = -887220; // full range (divisible by 60)
    int24 constant TICK_UPPER = 887220;

    uint256 constant NO_KYC_LIMIT = 1e14; // 0.0001 ETH — swaps below this need no verification
    uint256 constant ENHANCED_LIMIT = 1e18; // 1 ETH — above this needs ACCREDITED
    uint256 constant LIQUIDITY = 1e15;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("=== LEXIFI PHASE 1: PROOF OF LOOP ===");
        console.log("Deployer:", deployer);
        console.log("Deployer balance:", deployer.balance);
        console.log("");

        vm.startBroadcast(deployerKey);

        // --- 1. Deploy TestToken (mintable ERC20 for the compliance pool) ---
        TestERC20 token = new TestERC20(100_000e18);
        console.log("[1] TestToken deployed:", address(token));

        // --- 2. Deploy Phase1Prover (unlock-callback helper) ---
        Phase1Prover prover = new Phase1Prover(IPoolManager(POOL_MANAGER));
        console.log("[2] Phase1Prover deployed:", address(prover));

        // --- 3. Build PoolKey ---
        // currency0 = native ETH (address(0)), currency1 = TestToken
        // address(0) < any deployed address, so ordering is correct
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });
        PoolId poolId = poolKey.toId();
        console.log("[3] PoolKey built. PoolId:");
        console.logBytes32(PoolId.unwrap(poolId));

        // --- 4. Initialize pool (no policy yet = no compliance check) ---
        int24 tick = IPoolManager(POOL_MANAGER).initialize(poolKey, SQRT_PRICE_1_1);
        console.log("[4] Pool initialized at tick:", tick);

        // --- 5. Approve TestToken for Phase1Prover ---
        token.approve(address(prover), type(uint256).max);
        console.log("[5] TestToken approved for Phase1Prover");

        // --- 6. Seed liquidity (before policy = no compliance check) ---
        token.transfer(address(prover), 0); // ensure prover is known to token (no-op)
        prover.addLiquidity{value: 0.001 ether}(poolKey, TICK_LOWER, TICK_UPPER, int256(LIQUIDITY));
        console.log("[6] Liquidity seeded: 0.001 ETH + TestToken");

        // --- 7. Set pool policy on hook (deployer becomes pool admin) ---
        LexifiHook(HOOK).setPoolPolicy(poolKey, THRESHOLD_POLICY);
        console.log("[7] Pool policy set to ThresholdPolicy");

        // --- 8. Configure thresholds ---
        // noKycLimit = 1e14 (0.0001 ETH): below this, anyone can swap
        // enhancedLimit = 1e18: above this, need ACCREDITED
        // lpMinimum = DENIED (0): anyone can LP (pool already seeded)
        // swapMinimum = RETAIL (1): swaps above noKycLimit need basic KYC
        ThresholdPolicy(THRESHOLD_POLICY).setPoolConfig(
            poolId,
            NO_KYC_LIMIT,
            ENHANCED_LIMIT,
            ILexifiPolicy.AccessLevel.DENIED,
            ILexifiPolicy.AccessLevel.RETAIL
        );
        console.log("[8] ThresholdPolicy configured");
        console.log("    noKycLimit:", NO_KYC_LIMIT, "(0.0001 ETH)");
        console.log("    swapMinimum: RETAIL (1)");

        // --- 9. PASSING SWAP: small amount below noKycLimit ---
        // Amount: 1e13 (0.00001 ETH) < noKycLimit (1e14)
        // Expected: PASS (small trade, no KYC needed)
        prover.swap{value: 0.0001 ether}(poolKey, true, -int256(1e13));
        console.log("[9] PASSING SWAP executed: 0.00001 ETH (below noKycLimit)");

        vm.stopBroadcast();

        // --- 10. Print denied swap command ---
        console.log("");
        console.log("=== NEXT: DENIED SWAP ===");
        console.log("Run this command to execute the denied swap on-chain:");
        console.log("(Expected to revert with ComplianceDenied)");
        console.log("");

        // Encode the swap calldata for the denied attempt
        bytes memory swapCalldata = abi.encodeCall(
            prover.swap,
            (poolKey, true, -int256(1e15))
        );
        console.log("Target (Phase1Prover):", address(prover));
        console.log("Calldata:");
        console.logBytes(swapCalldata);
        console.log("");
        console.log("=== PHASE 1 SETUP COMPLETE ===");
        console.log("Pool has compliance hook + ThresholdPolicy active.");
        console.log("Passing swap recorded on-chain.");
        console.log("Run denied swap manually to complete proof-of-loop.");
    }
}
