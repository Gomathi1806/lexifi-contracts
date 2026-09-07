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

## POLICY AUDIT — 3 findings (2026-09-04) — FIXED IN CODE 2026-09-07, NOT YET DEPLOYED ⚠️

Follow-up to the swap/LP hole found in `ThresholdPolicy`. PoC tests in
`test/PolicyAsymmetryAudit.t.sol` (7 tests). **All three findings affect contracts already
deployed to Base mainnet.** No pool is known to be configured into any of them today, but they
must be fixed before an issuer relies on these policies.

> Method note: assertions must go through the enforcement comparison
> (`checkAccess().level >= minimumLevel(operation)`), not `checkAccess` alone. The hook discards
> the `reason` string whenever the level comparison passes, so a test asserting only on `reason`
> proves nothing. `test_PartiallyVerified_OnlyOneProvider_Denied` in `InstitutionalPolicy.t.sol`
> is exactly that mistake — it is named "Denied" and reports green on a case that is allowed.

**Finding 1 — `RegionalPolicy` swap/LP asymmetry (config-dependent).**
`checkAccess` ignores `operation`, so swap and LP diverge only via `minimumLevel`.
`setRegionConfig` accepts `minSwap` and `minLp` independently with no ordering constraint, so
any admin setting `minLp < minSwap` reopens the LP backdoor: an address barred from buying the
asset can still mint a position in it. Safe when the minimums match.
*Fix:* reject `minLp < minSwap` in `setRegionConfig`, or clamp at read time.
*Mitigated on the Permissioned Pools path only* by `LexifiAllowlistChecker.liquidityRequiresSwap`
(default true). Pools using `LexifiHook` directly are unprotected.

**Finding 2 — `RegionalPolicy.requireCountryAttestation` does not deny.** The branch returns
`(level, reason)` — the user's real level — instead of `AccessLevel.DENIED` the way
`ThresholdPolicy` does. The flag therefore changes nothing unless `minSwapLevel` is already
>= ACCREDITED, in which case it is redundant. An EU-only pool configured with
`requireCountry=true, minSwap=RETAIL` admits users with no country attestation. The config
option creates an illusion of enforcement.
*Fix:* return `AccessLevel.DENIED` in both the country and account branches.

**Finding 3 — `InstitutionalPolicy` N-of-M quorum is not enforced.** `highestTier` is only
updated for providers that PASSED, so a user cleared by even one provider returns at
>= `minimumTier`. The policy returns that level alongside "Insufficient institutional
verifications" — and the level comparison passes. **The headline feature of this policy never
gates anything.** A user verified by 1 of 3 required providers trades freely on a 2-of-3 pool.
Users no provider clears are still denied (`highestTier` stays 0), so the bug is confined to
partial-quorum cases — which is precisely the case the policy exists to handle.
*Fix:* return `AccessLevel.DENIED` when `passed < cfg.minimumProviders`.

`InstitutionalPolicy` is **not** vulnerable to Finding 1: its `minimumLevel` ignores
`operation`, so swap and LP can never diverge. The flip side is that it cannot express
different swap and LP requirements at all.

**Because all three are in deployed contracts, fixing them means redeploying the affected
policies and re-pointing pools** — the policies are immutable and Safe-owned. Sequence any fix
with that in mind.

## Phase 6 — Policy audit fixes (code 2026-09-07) — AWAITING REDEPLOY ⚠️

All three findings above are fixed in source and covered by tests. **Nothing has changed
on-chain yet** — the deployed policies are immutable, so the fix only lands when the two
policies are redeployed and pools are re-pointed. Until then Base mainnet still runs the
buggy v1 policies.

| Finding | Fix | Where |
|---|---|---|
| 1 — RegionalPolicy `minLp < minSwap` LP backdoor | `setRegionConfig` reverts `LpBelowSwapMinimum()`. `minLp > minSwap` is still allowed — only the backdoor direction is barred. | `RegionalPolicy.sol` |
| 2 — `requireCountryAttestation` / `requireAccountAttestation` no-ops | Both branches now return `AccessLevel.DENIED` instead of the user's real level. | `RegionalPolicy.sol` |
| 3 — InstitutionalPolicy N-of-M quorum not enforced | Returns `AccessLevel.DENIED` when `passed < cfg.minimumProviders`. | `InstitutionalPolicy.sol` |

`policyVersion()` on both is bumped **1 → 2** so an integrator can tell fixed from buggy
on-chain. `ThresholdPolicy`, `CoinbaseEASProvider`, `SelfAttestationProvider`, `LexifiHook`
and the Phase 5 contracts are **unchanged** — do not redeploy them.

**Tests: 127 pass** (was 124). The 7 PoC tests in `test/PolicyAsymmetryAudit.t.sol` were
inverted to assert correct behaviour and 3 were added (minLp-above-minSwap is still allowed;
account-attestation branch denies; quorum-met still admits).
`test_PartiallyVerified_OnlyOneProvider_Denied` in `InstitutionalPolicy.t.sol` — the test that
asserted only `bytes(reason).length > 0` and so reported green on an allowed case — now asserts
the level the enforcement path actually compares.

**Still unfixed by design:** `ThresholdPolicy` gates swaps on trade size but LPs on tier alone.
That asymmetry is inherent to the policy, not a misconfiguration, so config validation cannot
remove it. On the Permissioned Pools path `LexifiAllowlistChecker.liquidityRequiresSwap`
(default true) closes it; **pools using `LexifiHook` directly remain exposed.** Closing it in
the policy would need an LP-side amount rule, which changes the policy's semantics — a separate
decision, not an audit fix.

### Redeploy — not yet run

`script/DeployPolicyFixes.s.sol` deploys **only** the two changed policies and reuses the live
`CoinbaseEASProvider` (do NOT re-run `DeployPolicies.s.sol`, which would replace all five).

```bash
cd lexifi-v2-secure && source .env
COINBASE_PROVIDER=0xb5DEC225A104A276671A765aba3890EC88A2ca27 \
  forge script script/DeployPolicyFixes.s.sol --rpc-url https://mainnet.base.org
```

Dry run verified against live Base state 2026-09-07: simulates clean, est. **0.0000145 ETH**.
Add `--broadcast --verify` to execute.

Then, in order:
1. **Re-point each affected pool** — `LexifiHook.setPoolPolicy(poolKey, <v2 address>)`, called by
   that pool's **pool admin** (whoever first called `setPoolPolicy` for it — not necessarily the
   Safe). `requireApproval` is currently `false` on the hook, so no owner pre-approval is needed;
   if it is ever enabled, the Safe must `approvePolicy` first.
2. **Re-apply every pool config on the new policy.** `setRegionConfig` / `setInstitutionalConfig`
   state does NOT migrate. A pool pointed at a v2 policy with no config has `active == false`,
   which the policies treat as **open access** — skipping this step silently disables compliance
   on that pool. This is the dangerous step; do it in the same session as step 1.
3. Update `lexifi-sdk/src/addresses.ts`, both dashboard READMEs, technical doc §10, then sync
   `lexifi-dashboard/lexifi-sdk/` and redeploy the dashboard.

Current live pool count is 2 (`hook.totalPools()`), both from Phase 1 / Aug 7 testing on
`ThresholdPolicy` — so **no pool is known to be using RegionalPolicy or InstitutionalPolicy
today**, and the redeploy can be done without a live migration. Confirm before assuming.

## Phase 5 — Uniswap v4 Permissioned Pools integration (deployed 2026-09-04) ✅

| Contract | Base mainnet address |
|---|---|
| LexifiComplianceAdapter | `0xe59fB4347Ca17aA94BBd62eBb9921877b06B68eE` |
| LexifiAllowlistChecker | `0x3882cD541634b99DabB5443Dc0DC67Ba4eDe94bc` |

Both verified on BaseScan. Deploy txs `0x0c7e59f1…a8c3` (adapter) and `0xd9edfd7b…6250` (checker),
block `0x30819a5`. On-chain state confirmed: `checker.owner()` = Safe
`0x17ae269e27524E82F29ca76Cb39A151A90a34B7e`, `checker.compliance()` = the adapter,
`adapter.lexifiHook()` = `0xfE92DE69d2dDdcAc2f864C4cF84e8aD5E17D2880`, `paused()` = false,
and `supportsInterface(IAllowlistChecker)` = true (the ERC-165 probe Uniswap's
`PermissionsAdapter._updateAllowListChecker` runs).

**The checker denies every address right now — no tokens are bound.** That is the intended
resting state. See "Owner actions" below to activate it.

> **Verification gotcha:** `--verify` during `--broadcast` failed with
> `Could not detect deployment: Unable to locate ContractCode`. That is BaseScan indexer lag,
> not a deployment failure — the receipts were already `status 0x1`. Re-running
> `forge verify-contract` a few minutes later succeeded first try. Always check
> `cast code <addr>` before assuming a deploy failed.

### SDK (2026-09-04)

`@lexifi/sdk` bumped to **0.2.0**. Added `complianceAdapter` + `allowlistChecker` to
`LexifiDeployment`, plus `LexifiComplianceAdapterAbi`, `LexifiAllowlistCheckerAbi` and
`PermissionFlags`. Base Sepolia entries are `NOT_DEPLOYED`. Builds clean.

> **npm blocker (checked 2026-09-07):** `@lexifi/sdk` **is** on npm, but the published
> version is **1.0.0 from 2026-04-07** — a v1-era build pointing at hook `0x607c…5BFb` and
> zkPass `0x929E…b646`. Anyone running `npm install @lexifi/sdk` today gets that. Local
> source is 0.2.0, which is *lower* than published, so `npm publish` will be rejected until
> the version is bumped past 1.0.0 (suggest 1.1.0). Until then, do not advertise the npm
> install path.

### Original build notes

**Why:** Uniswap shipped Permissioned Pools on 2026-07-23. Its `PermissionsAdapter`
delegates every swap/LP decision to an `IAllowlistChecker` **the issuer must implement
and deploy** — Uniswap provides the socket, not the compliance logic.
`LexifiAllowlistChecker` is that implementation, backed by the existing policy registry
instead of a hand-maintained address list.

**Contracts:**
- `src/integrations/LexifiAllowlistChecker.sol` — extends Uniswap's `BaseAllowlistChecker`
  (`lib/v4-periphery/src/hooks/permissionedPools/`), composes on `ILexifiCompliance`.
- `test/LexifiAllowlistChecker.t.sol` — 20 tests (124 total pass as of 2026-09-07).
- `script/DeployAllowlistChecker.s.sol` — deploys `LexifiComplianceAdapter` (if not already
  live) + `LexifiAllowlistChecker`.

**Interface mismatch this contract resolves.** Uniswap asks
`checkAllowlist(account, tokenAddress) -> PermissionFlag` (`SWAP_ALLOWED 0x0001`,
`LIQUIDITY_ALLOWED 0x0002`). It passes **no poolId, no operation, and no trade size**.
Two adaptations bridge it:
1. `bindings[token] -> poolId` — Uniswap passes `tokenAddress` precisely so one checker can
   serve several assets.
2. `evaluationAmount` — pins the notional the policy is evaluated at, since trade size is
   unknowable here. `bindToken` rejects 0, which would make `ThresholdPolicy` return
   INSTITUTIONAL for everyone.

**Known limits (state these to issuers):** `checkAllowlist` is `view`, so this path emits no
`ComplianceCheckFailed` / `AuditRecord` — the Phase 2 audit trail has no counterpart here, and
denials surface only as a revert inside the adapter. Size-dependent gating cannot be expressed
at all. Pools needing either should keep using `LexifiHook` directly. The two are complementary.

**Compliance fix found while writing the tests:** `ThresholdPolicy` gates swaps on trade size
but gates LPs on tier alone, so a RETAIL address denied a large swap still cleared the raw LP
check — it could acquire the permissioned asset by minting a position instead of buying it.
Harmless inside `LexifiHook`; a real hole once it feeds an allowlist. Closed by the per-binding
`liquidityRequiresSwap` flag (default true). Worth auditing the other policies for the same
asymmetry.

### Deploy steps

Add `LEXIFI_HOOK` to `.env` (see `env.example`), then:

```bash
forge script script/DeployAllowlistChecker.s.sol --rpc-url https://mainnet.base.org
```

Dry run first (no `--broadcast`) — it checks `LEXIFI_HOOK` has code on-chain and prints the
Safe calldata. Verified against live Base state 2026-09-04; est. cost ~0.000015 ETH. Then:

```bash
forge script script/DeployAllowlistChecker.s.sol --rpc-url https://mainnet.base.org --broadcast --verify
```

### Owner actions (Safe `0x17ae…4B7e` — NOT the deployer)

The checker deploys with **zero bindings and therefore denies every address**. That is the
correct initial state: nothing is live until the Safe deliberately binds a token.

1. Set `PERMISSIONED_TOKEN` + `POOL_ID` in `.env` and re-run the script *without*
   `--broadcast` to print the `bindToken` calldata.
2. Execute it from Safe TX Builder against the checker address.
3. Confirm with `checker.previewPermissions(user, token)` — it returns the human-readable
   denial reason that the flag interface throws away.

### Then

- Issuer deploys a `PermissionsAdapter` via Uniswap's `PermissionsAdapterFactory`, passing this
  checker as the allowlist checker. `_updateAllowListChecker` runs an ERC-165 probe, so the
  checker must (and does) report `type(IAllowlistChecker).interfaceId`.
- Add the checker + compliance adapter addresses to `lexifi-sdk/src/addresses.ts`.

**Still to build:** an integration test against a real `PermissionsAdapter` from the factory.
The current tests mirror the adapter's bitmask check
(`(checkAllowlist(acct, tkn) & permission) == permission`, `PermissionsAdapter.sol:83`) rather
than driving the real contract.

**Note on other chains:** Coinbase Verifications attestations exist on Base only. On any other
chain `CoinbaseEASProvider` resolves every address to tier 0, and because this stack fails
closed that yields a pool denying everyone. The script warns when `block.chainid` is not Base.

### Repo hygiene fix (2026-09-04)

`foundry.toml` had `@openzeppelin/=lib/openzeppelin-contracts/`, a path that does not exist.
Nothing imported it before; Uniswap's `BaseAllowlistChecker` does. Repointed to
`lib/v4-core/lib/openzeppelin-contracts/`.
