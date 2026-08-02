# Lexifi v2 — Secure Redeploy Runbook

**Why this redeploy:** the previous owner key `0x22bc…a621` is compromised, and the
previously deployed `CoinbaseEASProvider` (`0x9Da4…E1d7`) has a critical bug (EAS
`recipient`/`attester` fields swapped → every verification silently returned tier 0).
Both are unrecoverable on-chain; all five contracts must be redeployed.

**What changed in v2 (this repo):**
1. `tx.origin` removed — users are resolved via `IMsgSender` on owner-trusted routers
   (works for Safe multisigs and ERC-4337 smart accounts; spoof-safe for everyone else).
2. EAS struct order fixed + `recipient == user` hardening in `CoinbaseEASProvider`.
3. Zero-address checks on all constructors and `transferOwnership`.
4. Deploy scripts take a separate `OWNER` (Smart Wallet / Safe) — the deployer EOA is
   throwaway and holds no power.
5. `MineSalt` bug fixed (was mining against the wrong CREATE2 factory).

All 63 Foundry tests pass. Full loop (hook → policy → provider → real Coinbase EAS
attestation) verified on an anvil fork of Base mainnet.

---

## 0. One-time prep

1. Create a **brand-new EOA** (MetaMask/Rabby → new account). This is the throwaway
   deployer. Send it ~0.005 ETH on Base.
2. Have your **Coinbase Smart Wallet address** ready (this becomes OWNER).
   Optional but better: create a Safe at https://safe.global on Base (2-of-3:
   Smart Wallet + hardware wallet + backup) and use the Safe address as OWNER.
3. `cp env.example .env`, fill in, `source .env`.

> Never reuse the hacked wallet `0x22bc…a621` for anything, and never send funds to it.

## 1. Deploy policies + provider

```bash
forge script script/DeployPolicies.s.sol --rpc-url https://mainnet.base.org --broadcast --verify
```
Record the 4 printed addresses.

## 2. Mine the hook salt

```bash
forge script script/MineSalt.s.sol
```
Copy the bytes32 salt into `.env` as `HOOK_SALT`, then `source .env` again.

## 3. Deploy the hook

```bash
forge script script/DeployHook.s.sol --rpc-url https://mainnet.base.org --broadcast --verify
```
The printed address must match the MineSalt prediction (ends with hook-permission bits `…880`-pattern).

## 4. Owner actions (from the Smart Wallet / Safe — NOT the deployer)

Because the owner is a smart wallet, use BaseScan's *Write Contract* tab (connect the
Coinbase Smart Wallet / Safe) on the new LexifiHook:

1. `setTrustedRouter(0x6fF5693b99212Da76ad316178A184AB56D299b43, true)`  — Universal Router (verified: has code on Base)
2. `setTrustedRouter(0x7C5f5A4bBd8fD63184577525326123B519429bDc, true)` — PositionManager (verified: its `poolManager()` returns the canonical PoolManager)

## 5. Prove the loop on mainnet (Phase 1)

1. `setPoolPolicy(poolKey, <ThresholdPolicy>)` for a WETH/USDC pool keyed to the new hook.
2. `ThresholdPolicy.setPoolConfig(poolId, 1000e18, 10000e18, 1, 1)`.
3. Initialize the pool + seed a small amount of liquidity (Universal Router / PositionManager).
4. Execute **one passing swap** from a Coinbase-verified wallet and **one denied swap**
   from an unverified wallet (above the no-KYC limit). Record both tx hashes — they are
   your public proof.

## 6. Update every reference

- `lexifi-dashboard/src/config/contracts.ts` → new 5 addresses
- README(s), technical doc §10, lexifiio.vercel.app deployment
- Mark `0xb8ab…2880`, `0x8916…3DF9`, and `0x9Da4…E1d7` as **deprecated/compromised** everywhere.

## v2 deployment (2026-07-19) — DEPRECATED

Deployed with Coinbase Smart Wallet `0xB469…6d68` as owner. Unmanageable because
BaseScan Write Contract can't send owner-only txns from Coinbase Smart Wallet
(gas-field bug: `maxPriorityFeePerGas cannot be null`). v2 contracts still exist
on-chain but are effectively orphaned — do not reference them anywhere.

v2 addresses (do not use): hook `0x67a9…2880`, provider `0xF701…A7ea`,
threshold `0x0b37…b74b`, regional `0xcF06…d6e2`, institutional `0xbe8a…88d5`.

## v3 deployment — Safe-owned — 2026-07-21 ✅

| Contract | v3 address (Base mainnet) |
|---|---|
| LexifiHook | `0xfE92DE69d2dDdcAc2f864C4cF84e8aD5E17D2880` |
| CoinbaseEASProvider | `0xb5DEC225A104A276671A765abA3890Ec88a2Ca27` |
| ThresholdPolicy | `0x75f4913F53b694fDda95E49456d163ca7AEF4199` |
| RegionalPolicy | `0xa99A89CD5A61e975fb11047d3ed455fCcaD9A44f` |
| InstitutionalPolicy | `0xaD09fc63080736b1dFC4048F3589C481225db5fb` |
| SelfAttestationProvider | `0x344E4917360F5b44680D097c5E4904Ac62c00483` |

Owner (all): Safe `0x17ae269e27524E82F29ca76Cb39A151A90a34B7e` (1/1 on Base,
signer `0x4122c8b8080c8960F52d3D1cCb3A8d85EFF1f039` in Rabby). All verified on
BaseScan. Hook + policies compiled from same code as v2 — no code change.

**Deployer/signer are the same address** (`0x4122…f039`, Rabby). Key is in
`.env`; remove after Safe operations settle. Never commit `.env`.

**Completed:**
1. ✅ Trusted routers set via Safe TX Builder (Universal Router + PositionManager).
2. ✅ Phase 1 proof-of-loop (2026-07-27) — see below.
3. ✅ Phase 2 denial-persistent audit trail (2026-08-02) — see below.

**Still pending:**
1. Retire everything in docs/site pointing at v1 or v2 addresses.

**Recently completed:**
4. ✅ SelfAttestationProvider deployed to Base mainnet (2026-08-02) — `0x344E4917360F5b44680D097c5E4904Ac62c00483`, verified on BaseScan, SDK addresses updated.

## Phase 1 — Proof of Loop (2026-07-27) ✅

Pool: ETH / TestToken (`0x3FC84d416A0F93578dB538737c34599138012402`)
PoolId: `0x49081a9762db094a03e395f3d38272a16b69c753c904d7e4dfd16bd09a47a718`
Policy: ThresholdPolicy (`0x75f4…4199`), noKycLimit=0.0001 ETH, swapMinimum=RETAIL
Helper: Phase1Prover (`0xe7312b5A058fF42C269922BFCe1CB6B19bAcE35B`)

| Step | TX Hash | Status |
|---|---|---|
| Deploy TestToken | `0x1227760e…dc67` | ✅ |
| Deploy Phase1Prover | `0xab1f963b…2d1a` | ✅ |
| Initialize pool | `0xf8d7fd20…9614` | ✅ |
| Seed liquidity (0.001 ETH) | `0xcbfe465f…308c` | ✅ |
| setPoolPolicy → ThresholdPolicy | `0xcf3d2f17…68e1` | ✅ |
| setPoolConfig (thresholds) | `0x921bff86…33ee` | ✅ |
| **PASSING swap** (0.00001 ETH, below threshold) | `0x593f00ab…fbda` | ✅ ComplianceCheckPassed |
| **DENIED swap** (0.001 ETH, above threshold) | `0x7eba76ae…4c22` | ❌ ComplianceDenied(RETAIL required, DENIED actual, "Swap requires basic verification") |

Hook state after: totalPools=1, totalChecks=1.
Deployer balance remaining: ~0.00425 ETH.

## Phase 2 — Denial-Persistent Audit Trail (2026-08-02) ✅

**Problem:** Solidity reverts roll back ALL state changes including events.
`ComplianceCheckFailed` and `AuditRecord` events emitted in `_enforceCompliance`
before the `ComplianceDenied` revert are lost forever — making denied swap audit
records invisible on-chain. A compliance system that can't prove it denied
something has a credibility gap.

**Solution:** Reconstruct denial records from on-chain failed transaction data.
Failed transactions (status=0) persist on-chain with their full calldata. The
dashboard decodes the swap function input from failed transactions to known
routers (Phase1Prover, Universal Router) and marks them as compliance denials.

**How it works:**
1. **Passes**: Indexed from `ComplianceCheckPassed` event logs on the hook
   (these persist because the transaction succeeds).
2. **Denials**: Discovered from failed transactions to known router addresses
   via Blockscout V2 API. The `swap()` calldata is decoded to extract amount,
   pool key, and user. The "RECONSTRUCTED" badge indicates the record was
   recovered from a reverted transaction.
3. **Policy registrations**: Indexed from `PoolPolicySet` events on the hook.

**Dashboard page:** `/audit` in lexifi-dashboard. No wallet connection required.
Fetches data from Blockscout V2 API (public, no API key, CORS-enabled).

**Files created/modified:**
- `lexifi-dashboard/src/app/audit/page.tsx` — Audit trail page (client-side)
- `lexifi-dashboard/src/config/abi.ts` — Added event topic hashes + Phase1Prover ABI
- `lexifi-dashboard/src/config/contracts.ts` — Added Phase1 addresses, Blockscout API
- `lexifi-dashboard/src/components/Nav.tsx` — Added Audit Trail nav link

## Phase 3 — Productize (2026-08-02) ✅

1. **`@lexifi/sdk`** — Published npm package with all ABIs, deployment addresses,
   types, and `fetchAuditTrail()` function. ESM + TypeScript, peer dep on viem.
2. **Dashboard policy config** — Pools page now has config forms for all three
   policies (Threshold, Regional, Institutional) with auto pool ID computation,
   on-chain config loading, and AccessLevel dropdowns.
3. **SDK import refactor** — Dashboard imports ABIs and addresses from `@lexifi/sdk`
   instead of duplicating them locally.

## Phase 4 — Second Verification Provider (2026-08-02) ✅

**Contract:** `SelfAttestationProvider` — implements `IVerificationProvider`. The
DEX operator verifies users off-chain (their own KYC/AML process) then stamps
wallets on-chain with an access tier. Supports:
- `attest(user, tier, expiry)` — single user attestation
- `attestBatch(users[], tiers[], expiries[])` — bulk registration
- `revoke(user)` — revoke access
- Expiry support (0 = never expires)
- Ownership transfer

**Why this provider:** Enables InstitutionalPolicy's N-of-M verification to work
with real, independent providers. A pool can require both Coinbase EAS verification
AND operator KYC sign-off — two independent trust anchors.

**Tests:** 21 tests covering attestation, batch, revocation, expiry, ownership,
and multi-provider InstitutionalPolicy integration (2-of-2 setup with
MockVerificationProvider as Coinbase stand-in).

**Files:**
- `src/policies/SelfAttestationProvider.sol` — Contract
- `test/SelfAttestationProvider.t.sol` — 21 Foundry tests
- `script/DeployPolicies.s.sol` — Updated to deploy SelfAttestationProvider
- `lexifi-sdk/` — Added `SelfAttestationProviderAbi`, `selfAttestationProvider` address field
- `lexifi-dashboard/src/app/checker/page.tsx` — Multi-provider verification display

**Deploy steps:** Run the updated `DeployPolicies.s.sol` script (it now deploys
6 contracts: CoinbaseEASProvider, ThresholdPolicy, RegionalPolicy,
InstitutionalPolicy, SelfAttestationProvider). Then update the SDK address to
the deployed `selfAttestationProvider` address.
