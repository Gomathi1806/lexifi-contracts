// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {RegionalPolicy} from "../src/policies/RegionalPolicy.sol";
import {InstitutionalPolicy} from "../src/policies/InstitutionalPolicy.sol";

/// @notice Redeploys ONLY the two policies changed by the 2026-09-07 audit fixes
///         (RegionalPolicy, InstitutionalPolicy) at policyVersion 2.
///
/// @dev Why a redeploy at all: both policies are immutable and Safe-owned, so the three audit
///      findings cannot be patched in place. ThresholdPolicy, CoinbaseEASProvider,
///      SelfAttestationProvider, LexifiHook and the Phase 5 contracts are UNCHANGED — do not
///      redeploy them, and do not re-run DeployPolicies.s.sol, which would needlessly replace
///      all five.
///
///      RegionalPolicy reuses the live CoinbaseEASProvider, so set COINBASE_PROVIDER to the
///      already-deployed address rather than deploying a new provider.
///
///      Dry run first (no --broadcast) — it prints the addresses and the follow-up Safe calls.
contract DeployPolicyFixes is Script {
    /// @dev Live Base mainnet deployment, for the sanity check below.
    address constant LIVE_PROVIDER_BASE = 0xb5DEC225A104A276671A765aba3890EC88A2ca27;
    address constant LIVE_REGIONAL_V1 = 0xA99A89Cd5A61e975fB11047D3ed455fCCad9A44F;
    address constant LIVE_INSTITUTIONAL_V1 = 0xaD09fc63080736b1dFC4048F3589C481225db5fb;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address owner = vm.envAddress("OWNER"); // Safe — never the deployer EOA
        address provider = vm.envAddress("COINBASE_PROVIDER");

        require(owner != deployer, "OWNER must differ from throwaway deployer");
        require(provider.code.length > 0, "COINBASE_PROVIDER has no code on this chain");

        if (block.chainid == 8453 && provider != LIVE_PROVIDER_BASE) {
            console.log("WARNING: COINBASE_PROVIDER is not the live Base provider");
            console.log("  expected:", LIVE_PROVIDER_BASE);
            console.log("  given:   ", provider);
        }
        if (block.chainid != 8453) {
            console.log("WARNING: not Base mainnet. Coinbase Verifications attestations exist");
            console.log("  on Base only - CoinbaseEASProvider resolves everyone to tier 0 here,");
            console.log("  and this stack fails closed, so every address would be denied.");
        }

        console.log("Deployer (throwaway):", deployer);
        console.log("Owner (Safe):        ", owner);
        console.log("Provider (reused):   ", provider);
        console.log("Chain ID:            ", block.chainid);

        vm.startBroadcast(deployerKey);

        RegionalPolicy regional = new RegionalPolicy(provider, owner);
        InstitutionalPolicy institutional = new InstitutionalPolicy(owner);

        vm.stopBroadcast();

        console.log("");
        console.log("=== FIXED POLICIES DEPLOYED (policyVersion 2) ===");
        console.log("RegionalPolicy v2:     ", address(regional));
        console.log("InstitutionalPolicy v2:", address(institutional));
        console.log("");
        console.log("Superseded (leave on-chain, stop referencing):");
        console.log("  RegionalPolicy v1:      %s", LIVE_REGIONAL_V1);
        console.log("  InstitutionalPolicy v1: %s", LIVE_INSTITUTIONAL_V1);
        console.log("");
        console.log("--- NEXT: re-point pools, then update references ---");
        console.log("1. For every pool using a v1 policy, its POOL ADMIN (the address that first");
        console.log("   called setPoolPolicy for that pool - not necessarily the Safe) must call");
        console.log("   LexifiHook.setPoolPolicy(poolKey, <v2 address>).");
        console.log("   requireApproval is currently false, so no owner pre-approval is needed.");
        console.log("   If it is ever turned on, the Safe must call approvePolicy first.");
        console.log("2. Re-apply each pool's config on the NEW policy - setRegionConfig /");
        console.log("   setInstitutionalConfig do NOT carry over. A v2 pool with no config is");
        console.log("   treated as open access (active=false), so this step is REQUIRED.");
        console.log("   Note: setRegionConfig now reverts LpBelowSwapMinimum() if minLp < minSwap.");
        console.log("3. Update lexifi-sdk/src/addresses.ts, both dashboard READMEs, and");
        console.log("   LEXIFI-TECHNICAL-DOCUMENTATION.md section 10, then redeploy the dashboard:");
        console.log("   vercel --prod --scope gomathi1806s-projects --cwd <repo>/lexifi-dashboard");
        console.log("4. Verify on BaseScan: forge verify-contract <addr> <Contract> --chain base");
    }
}
