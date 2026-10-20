# Response to the Olympix BugPoCer scan (2026-10-19)

Scan: Olympix BugPoCer full scan of `lexifi-contracts` at `cd80565`, provided through the
Uniswap Foundation Security Fund (UFSF) / Areta. Four Medium issues, all marked Verified. No
High or Critical issues.

This document covers each issue, what was changed, which live contracts are affected, and the
redeploy plan. **Nothing in this response has been deployed yet.** All fixes are in new source
files. The deployed `src/` files are unchanged, so the bytecode of every live contract still
reproduces from this repo.

## Summary

| # | Issue | Status | Fixed by |
|---|---|---|---|
| 1 | DENIED minimum level turns policy denials into passes | **Fixed in repo, not deployed** | `RegionalPolicyV4`, `InstitutionalPolicyV4` (new); `ThresholdPolicyV3` / `V4` already had it |
| 2 | First-writer config admin not bound to hook pool admin | **Fixed in repo, not deployed** | `LexifiPolicyConfigV2` + `LexifiHookV4` (V3 hook logic, already in repo at `5fc6f50`) |
| 3 | Unit mismatch threshold bypass | **Fixed in repo, not deployed** | `LexifiHookV4` + `ThresholdPolicyV4` + `LexifiSwapAmount` (new) |
| 4 | Policy squatting through an untrusted registry | **Fixed in repo, not deployed** | `LexifiHookV4` (creator-bound admin) + a new `LexifiComplianceAdapter` instance pointed at it |

All four are open on the live deployments until the redeploy below is done.

Regression tests: `test/OlympixRegression.t.sol`, 20 tests. For each issue, an `Old_` test runs
the Olympix PoC against the code it was found in and asserts that the bypass happens, which
shows the PoC is real. A `New_` test runs the same attack against the fixed contracts and asserts
the PoC's harm assertions. Verdicts are asserted through the enforcement comparison
`checkAccess().level >= minimumLevel(op)` and through the hook's own `beforeSwap` /
`beforeAddLiquidity`, never through `reason`.

`forge test`: **231 passed, 0 failed** (the 211 existing tests plus 20 new ones).

## Live addresses in scope

Base (8453). Hook owner and pool admin are the Safe `0x17ae269e27524E82F29ca76Cb39A151A90a34B7e`.

| Contract | Address |
|---|---|
| LexifiHook (v1) | `0xfE92DE69d2dDdcAc2f864C4cF84e8aD5E17D2880` |
| LexifiPolicyConfig (v1) | `0x9E005c201AEe5Db3c67b3658Cc18723dfDEe42E1` |
| RegionalPolicyV3 | `0x5309C741094e8901f9D2Ad1f31DC560006542a82` |
| InstitutionalPolicyV3 | `0xdA93C63212CF41dB3680319B3839f254aC319177` |
| ThresholdPolicy (v1) | `0x75f4913F53B694fDda95E49456D163Ca7AEf4199` |
| LexifiComplianceAdapter | `0xE59FB4347CA17Aa94BBD62eBB9921877B06b68eE` |
| LexifiAllowlistChecker (v1) | `0x3882cD541634b99DabB5443Dc0DC67Ba4eDe94bc` |

Robinhood Chain (4663). Hook owner is the EOA `0x4122c8b8080c8960F52d3D1cCb3A8d85EFF1f039`.

| Contract | Address |
|---|---|
| LexifiHook (v1) | `0x0B0400B268045Aa7E3B3ca18c1e1774f6C076880` |
| LexifiPolicyConfig (v1) | `0xF9f0d91100C86Acb6b6A56F17014CF03A53a028b` |
| RegionalPolicyV3 | `0xe1051391f608D0EeBE9FCF57DB96e087c7fd9cBD` |
| ThresholdPolicy (v1) | `0xBaa8ba3000Ee1087B0B52937078F4D4f146dF28C` |
| Adapter / allowlist checker | not deployed |

Live pool configs, read on-chain on 2026-10-20:

| Chain | Pool | Policy | Config |
|---|---|---|---|
| Base | WETH/USDC `0x5454…f424` | RegionalPolicyV3 | country required, swap min 2, LP min 2 |
| Base | ETH/TestToken `0x4908…a718` | ThresholdPolicy | noKyc 1e14, enhanced 1e18, LP min 0, swap min 1 |
| Robinhood | ETH/USDG `0x17fb…5f42` | ThresholdPolicy | noKyc 1e14, enhanced 1e18, LP min 0, swap min 2 |

`hook.totalPools()` is 2 on Base and 3 on Robinhood.

---

## Issue 1: DENIED minimum level turns policy denials into passes

**What it is.** Policies deny by returning `DENIED` (0). Enforcement is
`level >= minimumLevel(op)`. If a pool's configured minimum is `DENIED`, every denial compares
`0 >= 0` and passes. Olympix showed it on the v1 `ThresholdPolicy` (the large-trade check) and
the v1 `InstitutionalPolicy` (the quorum).

**Where it was still open.** `ThresholdPolicyV3` already had the fix (`_swapFloor`, commit
`cd80565`). `RegionalPolicyV3` and `InstitutionalPolicyV3` did not. Both returned the stored
minimum as is, so with a stored minimum of `DENIED`:

- RegionalPolicyV3 admitted wallets with no verification, and the country and account flags
  gated nothing.
- InstitutionalPolicyV3 admitted wallets that failed the N-of-M quorum.

**Fix.** `src/policies/RegionalPolicyV4.sol` and `src/policies/InstitutionalPolicyV4.sol`.
For a configured pool, `minimumLevel` for swap and add-liquidity is the stored minimum floored at
`RETAIL`. A verdict that passed every rule but sits below the floor is lifted to it. That only
happens when the stored minimum is `DENIED`, for example a verified tier-0 user. Removal
(operation 2) still requires `DENIED`, so exits are never gated. The config family and layout
are the same as V3, so existing configs read the same under V4.

**Why a floor and not rejecting DENIED minimums.** Config is written to the registry as opaque
bytes that the policy never sees, so the policy cannot reject anything at write time. The only
read-time alternative is to treat a `DENIED` minimum as unconfigured, which would close pools
whose admins meant "any verified user". The floor keeps that meaning and makes every denial
hold. It is the same rule `ThresholdPolicyV3` already uses, so all policies now follow one
invariant: a `DENIED` verdict always fails the comparison.

**Other change.** `InstitutionalPolicyV4.minimumLevel` returns `DENIED` for operation 2, like the
other policies. V3 returned `minimumTier` for every operation. The hook never checks removal, so
this changes no enforcement.

**Live exposure.** No live pool has a `DENIED` swap minimum, so the pools that exist today are
not exposed. On v1 `ThresholdPolicy` the LP minimum is 0 on both threshold pools. That is
"LP open" by design, since no LP deny path depends on it. A new pool configured with a `DENIED`
minimum on any of these policies would be exposed: Base RegionalPolicyV3 `0x5309…2a82`,
InstitutionalPolicyV3 `0xdA93…9177` and ThresholdPolicy `0x75f4…4199`; Robinhood RegionalPolicyV3
`0xe105…cBD` and ThresholdPolicy `0xBaa8…F28C`. Combined with issue 2, a stranger can write such
a config into any unclaimed slot.

**Until redeploy.** Configure every pool with minimums of at least `RETAIL` (1).

**Tests.** `test_Issue1_Old_RegionalV3_*`, `test_Issue1_Old_InstitutionalV3_*`,
`test_Issue1_Old_ThresholdV1_*` (bypass reproduced); `test_Issue1_New_*` (denied on V4, verified
users still pass, a stored RETAIL minimum is not loosened).

---

## Issue 2: First-writer config admin not bound to hook pool admin

**What it is.** `LexifiPolicyConfig` (v1) and the v1 policies' own setters make the first caller
for a `(family, poolId)` its permanent config admin, with no link to the hook's pool admin. A
stranger can claim an issuer's pool, write an open config, and lock the issuer out.

**Status.** Fixed in the repo at `5fc6f50`, not deployed. `LexifiPolicyConfigV2` keeps no admin
of its own: a write is allowed only if `msg.sender == hook.poolAdmin(poolId)`. The new hook
(`LexifiHookV4`, which keeps LexifiHookV3's admin binding) sets that admin when the pool is
created, through `createPool`, which is the only way to initialize a pool on it. So there is no
slot to claim. The V4 policies have no per-pool storage and read only from the registry.

**Live exposure.** Base `LexifiPolicyConfig` `0x9E00…42E1` and Robinhood `0xF9f0…028b`: every
slot that has not been written yet can be claimed by anyone. The Base WETH/USDC regional slot is
already held by the Safe. The v1 `ThresholdPolicy` contracts (`0x75f4…4199`, `0xBaa8…F28C`) have
the same first-writer rule in `setPoolConfig`. Their live pools are already claimed.

**Until redeploy.** Before pointing any pool at a registry-backed policy, have its admin write the
config in the same batch.

**Tests.** `test_Issue2_Old_RegistryV1_StrangerClaimsSlot`,
`test_Issue2_New_RegistryV2_StrangerCannotWrite`. The existing `test/AdminBinding.t.sol` covers
V2 in more depth.

---

## Issue 3: Unit mismatch threshold bypass

**What it is.** The hooks pass `|amountSpecified|` to the policy and drop `zeroForOne` and the
exact-in/out sign. Those decide whether the number is a currency0 or a currency1 amount, and the
swapper picks both. `ThresholdPolicy` / `ThresholdPolicyV3` compare that number against one pair
of limits. An unverified wallet states the swap on the lower-decimal side: on a TOKEN/USDC pool
with `noKycLimit = 1e14` ("0.0001 ETH"), 1e14 USDC base units ($100M) reads as a small trade.

**Design note.** Two options were considered:

1. Add a swap-specific entry point to the policy interface (e.g.
   `checkSwap(poolId, user, zeroForOne, amountSpecified)`). This is a cleaner signature, but it
   changes `ILexifiPolicy`, which third-party venues (`ILexifiCompliance`, Aqua0), the adapter and
   the allowlist checker all depend on, and it would need interface detection in the hook.
2. **Chosen:** keep `ILexifiPolicy` unchanged and say which currency the amount is in, inside the
   `amount` argument. Bit 255 set means currency1, clear means currency0
   (`src/libraries/LexifiSwapAmount.sol`). `ILexifiPolicy` has always documented `amount` as
   "in token0 terms", so a plain number keeps its documented meaning. The v1 and V3 hooks were
   the ones not following that.

The amount is in currency1 exactly when `zeroForOne != exactIn` (table in `LexifiSwapAmount`).
The magnitude saturates at 2^255 − 1, which only matters for `type(int256).min`. Saturating
upward makes a check stricter, never looser.

**Fix.**

- `src/LexifiHookV4.sol`: LexifiHookV3 with `beforeSwap` passing
  `LexifiSwapAmount.encode(zeroForOne, amountSpecified)`, and a `checkSwapCompliance(key, user,
  zeroForOne, amountSpecified)` view that previews a swap exactly as `beforeSwap` checks it.
  Nothing else changed. The swap `amount` in `ComplianceCheckPassed` / `AuditRecord` is the
  encoded value. Decode it with `LexifiSwapAmount.decode`.
- `src/policies/ThresholdPolicyV4.sol`: `noKycLimit0/enhancedLimit0` and
  `noKycLimit1/enhancedLimit1`, each in that currency's own base units, picked by the flag. The
  config layout changed, so it uses a new family, `keccak256("lexifi.policy.threshold.percurrency")`.
  All ThresholdPolicyV3 behaviour is kept, including `_swapFloor`.

**Compatibility.**

- Regional and Institutional policies ignore `amount`, so they are unaffected.
- A policy that reads `amount` but not the flag (ThresholdPolicyV3) sees every currency1 amount
  as above every limit. That fails closed: currency1 swaps need ACCREDITED. Tested in
  `test_Issue3_New_HookV4WithThresholdV3FailsClosed`.
- ThresholdPolicyV4 behind the v1 or V3 hook would read every swap as currency0, so the
  currency1 bypass would remain. **Use ThresholdPolicyV4 only with LexifiHookV4.**
- Adapter and allowlist-checker callers pass a plain amount, which is read as currency0. To state
  a currency1 amount, set bit 255 (`ThresholdPolicyV4.encodeSwapAmount`, or
  `LexifiSwapAmount.encodeCurrency`).

**Known limitation.** Using per-currency limits means no oracle and nothing that pool-price
manipulation can move. But the two limits are set at one price, and the bands drift apart if the
price moves a long way. Issuers re-set the config, or set both sides conservatively. To require
verification for every swap stated in one currency, set that currency's `noKycLimit` to 0.

**Live exposure.**

- **Robinhood ETH/USDG** (ThresholdPolicy `0xBaa8…F28C`, `noKycLimit = 1e14`): a swap stated in
  USDG (6 decimals) up to 1e14 base units, 100,000,000 USDG, needs no attestation. The pool had
  zero liquidity when read on 2026-10-15.
- **Base ETH/TestToken** (ThresholdPolicy `0x75f4…4199`): the same 1e14 / 1e18 limits apply to
  TestToken amounts at whatever the pool price is.

**Until redeploy.** The pool admin can set `noKycLimit = 0` on both threshold pools. Then every
non-zero swap needs `swapMinimum`, in either currency. On Base the pool admin is the Safe; on
Robinhood it is the ThresholdPolicy `poolAdmins` entry. This removes the open band but closes
the bypass. No transaction has been sent.

**Tests.** `test_Issue3_Old_HookV3_ThresholdV3_UsdcSideBypass`,
`test_Issue3_Old_HookV1_ThresholdV1_UsdcSideBypass` (bypass reproduced);
`test_Issue3_New_HookV4_ThresholdV4_UsdcSideDenied` (the PoC's exact-in and exact-out $100M USDC
swaps are denied, small swaps in either token pass, bands apply per currency);
`testFuzz_Issue3_New_FourShapesUseTheirCurrency`, `testFuzz_Issue3_EncodeDecodeRoundTrip`,
`test_Issue3_New_AdapterPlainAmountIsCurrency0`.

---

## Issue 4: Policy squatting through an untrusted registry

**What it is.** `LexifiComplianceAdapter` (Base `0xE59F…68eE`) serves whatever policy LexifiHook
v1 has stored for a pool id. On v1, `setPoolPolicy` accepts any PoolKey, including pools on other
hooks, and makes the first caller its permanent admin. An attacker can register a venue's pool
first, with an admit-all or reverting policy, and every adapter consumer then enforces it.

**Status.** Fixed in the repo, not deployed. `LexifiHookV4` (V3 admin logic):
`setPoolPolicy` is admin-only; `createPool` requires `key.hooks == this` and makes the creator
the admin; `beforeInitialize` rejects any other initializer. There is nothing to squat. The fix
needs a **new instance** of `LexifiComplianceAdapter` with `lexifiHook = LexifiHookV4`. The
adapter's source is unchanged; its `lexifiHook` is immutable, so the live one stays bound to v1.

**Residual behaviour, documented.** The adapter returns `allowed = true` for a pool id that has
no policy, as before. Under V4, pools on another hook can never have a Lexifi policy, so a venue
must check `hasPolicy(poolId)` and treat `false` as "not governed". `LexifiAllowlistCheckerV2`
already refuses to bind a pool with no policy. A fail-closed adapter variant is a possible
follow-up; it is not in this change.

**Live exposure.** Base adapter `0xE59F…68eE`. No venue is integrated today, and allowlist
checker v1 `0x3882…94bc` binds no tokens, so it denies everyone. On both chains the v1 hooks
themselves accept a first-writer `setPoolPolicy` for any unclaimed pool id.

**Until redeploy.** Do not point any venue or checker binding at the Base adapter.

**Tests.** `test_Issue4_Old_HookV1_AdapterServesSquattersPolicy`,
`test_Issue4_New_HookV4_NoSquatting` (squatting reverts for foreign and Lexifi pools, the Lexifi
Safe has no override, the adapter denies an unverified $1M swap, a verified trader is not
bricked).

---

## Redeploy plan (Base, through Safe TX Builder)

Do not start until the Safe threshold is raised to 2 of 2 (CLAUDE.md open item 1).

New stack: **LexifiHookV4, LexifiPolicyConfigV2, RegionalPolicyV4, InstitutionalPolicyV4,
ThresholdPolicyV4, LexifiComplianceAdapter (new instance), LexifiAllowlistCheckerV2.** The
providers are reused unchanged: CoinbaseEASProvider `0xb5DE…ca27` and SelfAttestationProvider
`0x344E…0483`.

Each deployment can be a Safe transaction to the canonical CREATE2 factory
`0x4e59b44847b379578588920cA78FbF26c0B4956C` (data = `salt ‖ initcode`), so no EOA is involved.
Or a deployer EOA can send them, as long as every constructor `owner` argument is the Safe. None
of the new contracts except the hook has an owner.

Order, because each step needs the address from the one before:

1. **LexifiHookV4** `(PoolManager 0x4985…2b2b, owner = Safe)`, through CREATE2 with a salt mined
   for `BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_SWAP` (adapt `script/DeployHook.s.sol`,
   which mines against the exact creation code).
2. **LexifiPolicyConfigV2** `(hook = LexifiHookV4)`.
3. **Policies**, all with `registry = LexifiPolicyConfigV2`:
   `RegionalPolicyV4(CoinbaseEASProvider, registry)`, `InstitutionalPolicyV4(registry)`,
   `ThresholdPolicyV4(provider, registry)`.
4. **LexifiComplianceAdapter** `(lexifiHook = LexifiHookV4)`.
5. **LexifiAllowlistCheckerV2** `(compliance = adapter from step 4)`.
6. **Safe batch on LexifiHookV4**: `setTrustedRouter(UniversalRouter 0x6fF5…9b43, true)`,
   `setTrustedRouter(PositionManager 0x7C5f…9bDc, true)`; `approvePolicy` for each V4 policy;
   `setRequireApproval(true)`.
7. **Safe batch, new pools.** For WETH/USDC: `hookV4.createPool(key with hooks = LexifiHookV4,
   sqrtPriceX96, RegionalPolicyV4)`, then
   `registryV2.setConfig(keccak256("lexifi.policy.regional"), newPoolId,
   RegionalPolicyV4.encodeConfig(true, false, 2, 2))`. Put both in one batch, so the pool is
   never live without its config. It would fail closed anyway, because unconfigured means denied.
   The pool id changes, since the hook address is part of the PoolKey. LPs migrate by removing
   from the old pool, which is never gated, and adding to the new one.
8. **Safe batch, close the old pools on hook v1** once liquidity has moved.
   - WETH/USDC: `LexifiPolicyConfig(v1).clearConfig(regional family, 0x5454…f424)`.
     RegionalPolicyV3 then fails closed, and removals still work. Better: overwrite it with an
     inactive config, `abi.encode(false, false, 0, 0, false)`, so the Safe keeps the slot instead
     of freeing it for the first writer.
   - Phase 1 ETH/TestToken: v1 ThresholdPolicy treats an inactive config as **open**, so don't
     deactivate it. In one batch, first write an inactive regional config for `0x4908…a718` into
     the v1 registry (claiming the slot), then `hookV1.setPoolPolicy(key, RegionalPolicyV3)`.
     Doing it in that order means no stranger can claim the slot between the two calls.
9. **Verify** every new contract on BaseScan, Blockscout and Sourcify, and check bytecode
   reproducibility.
10. **Publish**: update `lexifi-sdk/src/addresses.ts` (adding the threshold config family), the
    vendored SDK in the dashboard, the README and the runbook. Open a `Uniswap/hooklist` PR for
    the new hook address.

**Robinhood (4663).** The same stack and order, with `SelfAttestationProvider 0xC9F3…201B`
instead of Coinbase. The ETH/USDG pool moves to `ThresholdPolicyV4` with per-currency limits
(for example 1e14 wei of ETH and 0.30 USDG = 3e5). The hook owner is the EOA `0x4122…f039`;
move ownership to a Safe on 4663 first if one is available.

## Files in this change

- `src/LexifiHookV4.sol` (new)
- `src/libraries/LexifiSwapAmount.sol` (new)
- `src/policies/RegionalPolicyV4.sol` (new)
- `src/policies/InstitutionalPolicyV4.sol` (new)
- `src/policies/ThresholdPolicyV4.sol` (new)
- `test/OlympixRegression.t.sol` (new, 20 tests)
- `docs/OLYMPIX-SCAN-RESPONSE.md` (this file)

No deployed source file was edited.
