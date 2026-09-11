# Lexifi Contracts

[![test](https://github.com/Gomathi1806/lexifi-contracts/actions/workflows/test.yml/badge.svg)](https://github.com/Gomathi1806/lexifi-contracts/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Pool-level compliance for Uniswap v4. A single hook routes every swap and liquidity addition
to the policy registered for that pool, and the policy decides from on-chain identity
attestations. The contract enforces the rule, not a frontend, and withdrawals are never
blocked.

Live on Base mainnet · Solidity 0.8.26 · Foundry · 162 tests

```
Pool         Policy                  Rule
WETH/USDC    RegionalPolicyV3        country-attested, ACCREDITED to swap or add liquidity
RWA/USDC     InstitutionalPolicyV3   cleared by 2 of 3 independent providers
ETH/TOKEN    ThresholdPolicy         no KYC below the limit, verified above it
MEME/WETH    (none)                  open, a standard v4 pool
```

## How it works

```
                    Uniswap v4 PoolManager
                              │
                         LexifiHook ──── beforeSwap, beforeAddLiquidity: enforce
                              │          beforeRemoveLiquidity: not a hook permission,
                              │          so exits can never be blocked
          ┌───────────────────┼───────────────────────┐
   ThresholdPolicy     RegionalPolicyV3     InstitutionalPolicyV3
                              └───────────┬───────────┘
                                LexifiPolicyConfig ──── per-pool config that
                                                        survives policy redeploys
          ┌───────────────────────────────┴───────────┐
  CoinbaseEASProvider                        SelfAttestationProvider
  Coinbase Verifications (Base only)         the operator's own KYC (any chain)

  Permissioned Pools path:
  Uniswap PermissionsAdapter → LexifiAllowlistChecker → LexifiComplianceAdapter → pool policy
```

- **The hook** looks up the pool's policy and reverts unless the user's level meets the
  policy's minimum for that operation. It takes the real user from `IMsgSender.msgSender()` on
  routers the owner has marked trusted, and never reads `tx.origin`.
- **Policies** decide. The V3 policies read per-pool configuration from `LexifiPolicyConfig`,
  keyed by a constant family id, so policy logic can be redeployed without migrating
  configuration. A pool with no configuration is denied.
- **Providers** turn identity data into a tier: 0 DENIED, 1 RETAIL, 2 ACCREDITED,
  3 INSTITUTIONAL.
- **Every check is recorded.** Passes emit events. A denial reverts, which rolls its events
  back, so denials are reconstructed from reverted transactions by the dashboard's `/audit`
  page and the SDK's `fetchAuditTrail`.

Enforcement is always `checkAccess(...).level >= minimumLevel(operation)`. A deny path has to
fail that comparison, and returning `DENIED` from both sides passes it. That mistake is the
root of two of the three audit findings below, which is why the tests assert through the
comparison rather than on the returned reason.

## Two integration paths

| | `LexifiHook` (direct) | `LexifiAllowlistChecker` (Permissioned Pools) |
|---|---|---|
| Sees pool id | Yes | No: resolved through a `token → poolId` binding |
| Sees operation (swap vs LP) | Yes | No: expressed as permission flags |
| Sees trade size | Yes | No: evaluated at a fixed `evaluationAmount` |
| Amount-based rules | Yes | Not expressible |
| On-chain audit trail | Yes, events | No: `checkAllowlist` is `view` |
| Works with Uniswap's `PermissionsAdapter` | No | Yes |

Pools that need size-dependent rules or the audit trail should use the hook directly.

## Deployments: Base mainnet (chainId 8453)

Confirmed on-chain 2026-09-11. Integrators should take addresses from
[`@lexifi/sdk`](https://github.com/Gomathi1806/lexifi-sdk).

| Contract | Address | Owner | State |
|---|---|---|---|
| LexifiHook | [`0xfE92DE69d2dDdcAc2f864C4cF84e8aD5E17D2880`](https://basescan.org/address/0xfE92DE69d2dDdcAc2f864C4cF84e8aD5E17D2880) | Safe | 2 pools registered |
| LexifiPolicyConfig | [`0x9E005c201AEe5Db3c67b3658Cc18723dfDEe42E1`](https://basescan.org/address/0x9E005c201AEe5Db3c67b3658Cc18723dfDEe42E1) | none | Per-pool admins, no override |
| RegionalPolicyV3 | [`0x5309C741094e8901f9D2Ad1f31DC560006542a82`](https://basescan.org/address/0x5309C741094e8901f9D2Ad1f31DC560006542a82) | Safe | Governs WETH/USDC |
| InstitutionalPolicyV3 | [`0xdA93C63212CF41dB3680319B3839f254aC319177`](https://basescan.org/address/0xdA93C63212CF41dB3680319B3839f254aC319177) | Safe | No pool yet |
| ThresholdPolicy | [`0x75f4913F53B694fDda95E49456D163Ca7AEf4199`](https://basescan.org/address/0x75f4913F53B694fDda95E49456D163Ca7AEf4199) | Safe | Governs the Phase 1 proof pool |
| CoinbaseEASProvider | [`0xb5DEC225A104A276671A765aba3890EC88A2ca27`](https://basescan.org/address/0xb5DEC225A104A276671A765aba3890EC88A2ca27) | none | Configuration fixed at deployment |
| SelfAttestationProvider | [`0x344E4917360F5b44680D097c5E4904Ac62c00483`](https://basescan.org/address/0x344E4917360F5b44680D097c5E4904Ac62c00483) | Safe | |
| LexifiComplianceAdapter | [`0xE59FB4347CA17Aa94BBD62eBB9921877B06b68eE`](https://basescan.org/address/0xE59FB4347CA17Aa94BBD62eBB9921877B06b68eE) | none | Hook address fixed at deployment |
| LexifiAllowlistChecker | [`0x3882cD541634b99DabB5443Dc0DC67Ba4eDe94bc`](https://basescan.org/address/0x3882cD541634b99DabB5443Dc0DC67Ba4eDe94bc) | Safe | No tokens bound, so it denies every address until the Safe binds one |

Safe: [`0x17ae269e27524E82F29ca76Cb39A151A90a34B7e`](https://app.safe.global/base:0x17ae269e27524E82F29ca76Cb39A151A90a34B7e),
1-of-1. Owner-only calls go through Safe Transaction Builder, never a deployer key.

**Live pools**

| Pool | Pool ID | Policy |
|---|---|---|
| WETH/USDC, fee 0.3% | `0x54545d84902d4f5864c9d3f5c14d7dd961c8218dd41fef3292c4eac636e8f424` | RegionalPolicyV3: country attestation required, ACCREDITED to swap or add liquidity |
| ETH/TestToken (Phase 1 proof) | `0x49081a9762db094a03e395f3d38272a16b69c753c904d7e4dfd16bd09a47a718` | ThresholdPolicy |

Pool-admin rights for both pools (on the hook, in the registry for WETH/USDC, and in
ThresholdPolicy) have belonged to the Safe since 2026-09-11. Pool changes go through Safe
Transaction Builder, like every other owner action.

**Reproducible build.** For every contract above, and for the two retired v2 policies below,
the runtime bytecode on Base is identical to what this repository compiles, with immutables
masked. For all of them except `LexifiComplianceAdapter` the metadata hash matches as well, so
the committed source is exactly what was deployed. The adapter's executable code is identical;
its metadata hash differs, which means the source text compiled at deployment differed from
the committed file only in non-executable content. The verified source on BaseScan is the
exact deployed text.

Because the metadata hash covers the source text, **deployed files under `src/` are frozen**:
changing even a comment would break that match. Status notes belong in this README and in the
runbook, not in those files.

### Proof transactions (Phase 1, 2026-07-27)

ETH/TestToken pool on ThresholdPolicy with `noKycLimit = 0.0001 ETH`.

| What | Transaction |
|---|---|
| Initialize the pool | [`0xf8d7fd20…9614`](https://basescan.org/tx/0xf8d7fd20916ec9f80720059102ac9486e6e4eb1cab668d234706f5b5325a9614) |
| Register ThresholdPolicy on it | [`0xcf3d2f17…68e1`](https://basescan.org/tx/0xcf3d2f17fe078fb679a564ea8ad55fe9f6c779c7839e2ee9a2a09acec8e168e1) |
| Swap below the threshold passes | [`0x593f00ab…fbda`](https://basescan.org/tx/0x593f00ab2d229683caaecc1adf3fd659e2249e6c1a6b16681a4b93d09cb3fbda) |
| Swap above the threshold is denied | [`0x7eba76ae…4c22`](https://basescan.org/tx/0x7eba76aedf5e540fdc3d31419537ebedd9c5cd951a36e59c6364758a85f44c22) |

### Retired: do not use

All still on-chain, since contracts cannot be deleted.

| What | Addresses | Why |
|---|---|---|
| v1 generation | hook `0xb8ab…2880`, provider `0x9Da4…E1d7`, threshold `0x1074…2259`, regional `0x5568…F029`, institutional `0x3120…fC30`, zkPass `0x929E…b646` | Owner key `0x22bc…a621` was compromised. The provider also had EAS `recipient` and `attester` swapped, so every check returned tier 0. |
| v2 generation | hook `0x67a9…2880`, provider `0xF701…A7ea`, threshold `0x0b37…b74b`, regional `0xcF06…d6e2`, institutional `0xbe8a…88d5` | Owned by a Coinbase Smart Wallet that BaseScan cannot drive. Orphaned. |
| Regional and Institutional policy, logic v1 | `0xA99A89Cd5A61e975fB11047D3ed455fCCad9A44F`, `0xaD09fc63080736b1dFC4048F3589C481225db5fb` | Audit findings 2 and 3. Superseded by V3 on 2026-09-07. |
| Regional and Institutional policy, logic v2 | `0xf4f6af6ee5ff4a1bf712470e00fea2b6bafbf32c`, `0xaa3f1309219231091b606ca256771e51c3e9d822` | Carried the audit fixes, but V3 replaced them the same day before any pool used them. |

## Security

**There has been no third-party audit yet.** An internal review on 2026-09-04 found three
issues. Each was reproduced as a failing test before it was fixed, and all fixes have been live
since 2026-09-07.

| # | Finding | Resolution |
|---|---|---|
| 1 | RegionalPolicy accepted `minLp < minSwap`, which let an address barred from swapping acquire the asset by providing liquidity | V3 clamps `minLp` up to `minSwap` at read time; `validateConfig` reports when it applies |
| 2 | RegionalPolicy's country and account attestation flags returned the user's real level instead of denying | V3 denies |
| 3 | InstitutionalPolicy's N-of-M quorum never gated: one passing provider cleared the user | V3 denies when fewer than `minimumProviders` pass |
| – | Pools pointed at a policy but never configured traded freely | V3 fails closed |

The v1 policies with findings 2 and 3 are still on-chain but no pool uses them. Proofs of
concept are in `test/PolicyAsymmetryAudit.t.sol`, and the full write-up is in
`DEPLOYMENT-RUNBOOK.md`.

### Known limitations

- **ThresholdPolicy gates liquidity on tier alone.** Through the hook, a RETAIL address denied
  a large swap can still add liquidity. The Permissioned Pools path closes this with
  `liquidityRequiresSwap` (on by default). Closing it inside the policy would change what the
  policy means.
- **The Permissioned Pools path cannot see trade size and emits nothing**, because Uniswap's
  interface passes no pool id, operation or amount and is `view`.
- **Coinbase Verifications exist only on Base.** Elsewhere `CoinbaseEASProvider` returns tier 0
  for everyone and the stack fails closed, so other chains need `SelfAttestationProvider`.
- **Users behind a router the owner has not marked trusted** are identified as the router, so
  they are denied unless the router itself is verified.
- **Policies are trusted code.** The hook's `requireApproval` switch restricts pools to
  owner-approved policies, and it is currently off.

The full table is in [§14 of the technical documentation](docs/TECHNICAL-DOCUMENTATION.md).

## Build and test

```bash
git clone --recurse-submodules https://github.com/Gomathi1806/lexifi-contracts
cd lexifi-contracts
forge build
forge test
```

Every test runs locally; no RPC endpoint or key is needed. CI runs the full suite on every
push.

| Suite | What it covers |
|---|---|
| `LexifiHook.t.sol` | Policy registration and admin rights, enforcement on swap and liquidity, exits never blocked, owner functions, events |
| `ThresholdPolicy.t.sol` | Amount tiers for every user tier, liquidity gating, configuration and access control |
| `InstitutionalPolicy.t.sol` | N-of-M quorum, asserted through the enforcement comparison |
| `SelfAttestationProvider.t.sol` | Operator attestations, expiry, batching and revocation |
| `PolicyAsymmetryAudit.t.sol` | The three audit findings, now asserting the fixed behaviour |
| `PolicyConfigRegistry.t.sol` | The config registry and V3 policies: admin rights, fail-closed default, read-time clamps, migrated config matching legacy behaviour |
| `Aqua0Integration.t.sol` | A third-party venue adapter calling `LexifiComplianceAdapter` from `beforeSwap` |
| `LexifiAllowlistChecker.t.sol` | The Permissioned Pools checker on its own: flags, bindings, pause, fail-closed |
| `PermissionsAdapterIntegration.t.sol` | Uniswap's real `PermissionsAdapterFactory` and `PermissionsAdapter` with the Lexifi checker plugged in, including a fuzzed check that adapter, checker and `previewPermissions` always agree |

## Deploying

Scripts are in `script/`. [`DEPLOYMENT-RUNBOOK.md`](DEPLOYMENT-RUNBOOK.md) is the full
changelog: every deployment, the script that produced it, owner actions, and the traps worth
knowing before touching a live pool. Copy `env.example` to `.env` to run a script, and never
commit `.env`.

## Repository layout

```
src/
  LexifiHook.sol                   the hook
  LexifiPolicyConfig.sol           per-pool configuration registry
  policies/                        ThresholdPolicy, RegionalPolicyV3, InstitutionalPolicyV3,
                                   both identity providers, and the retired Regional and
                                   Institutional logic the tests compare against
  integrations/                    LexifiComplianceAdapter, LexifiAllowlistChecker
  interfaces/  libraries/
script/                            deployment and proof scripts
test/                              the nine suites; mocks in test/mocks
docs/TECHNICAL-DOCUMENTATION.md    contract reference, flows, access control, security model
DEPLOYMENT-RUNBOOK.md              deployment changelog
```

## Related

- [`@lexifi/sdk`](https://github.com/Gomathi1806/lexifi-sdk): addresses, ABIs and types for
  integrators
- [Operator dashboard](https://lexifiio.vercel.app)
  ([source](https://github.com/Gomathi1806/Lexifi_uniswap_v4hook_compliance))

## License

MIT. Built by a graduate of the Uniswap v4 Hook Incubator (Atrium Academy).
