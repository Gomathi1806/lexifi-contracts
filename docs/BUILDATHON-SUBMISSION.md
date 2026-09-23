# Lexifi — compliance rules enforced inside Robinhood Chain pools

**Arbitrum Open House Buildathon · Robinhood Chain track · September 2026**

## One line

Lexifi lets a Uniswap v4 pool on Robinhood Chain decide who may trade in it — jurisdiction, KYC
level or trade size — and enforces that rule inside the pool contract, where no frontend can route
around it.

## The problem this track has

Robinhood Chain exists to trade assets that carry real transfer restrictions: tokenized stocks,
regulated stablecoins, RWAs. Those restrictions are legally binding, but on a DEX they are usually
checked in a frontend — and a frontend is a suggestion. A custom router ignores it.

The chain has Uniswap v4 and its full periphery. What it does not have is the eligibility layer that
regulated assets need before they can sit in an open pool.

Robinhood Chain also cannot inherit Base's answer. We verified by direct RPC probe that the EAS
predeploy, the Coinbase attestation indexer and the Coinbase attester **all have no code on 4663**.
Any compliance stack that depends on Coinbase Verifications fails closed here and denies every
wallet on the chain.

## What we built and deployed

A complete policy stack on Robinhood Chain mainnet, plus a live pool that enforces it.

| Contract | Address |
|---|---|
| LexifiHook | `0x0B0400B268045Aa7E3B3ca18c1e1774f6C076880` |
| SelfAttestationProvider | `0xC9F31Cb33BEC349691E11A6C62B1428C3c7C201B` |
| LexifiPolicyConfig | `0xF9f0d91100C86Acb6b6A56F17014CF03A53a028b` |
| RegionalPolicyV3 | `0xe1051391f608D0EeBE9FCF57DB96e087c7fd9cBD` |
| ThresholdPolicy | `0xBaa8ba3000Ee1087B0B52937078F4D4f146dF28C` |

All five are **exact matches on Sourcify** for chain 4663; LexifiHook, SelfAttestationProvider and
ThresholdPolicy also show as verified on Blockscout, and the remaining two are in its queue.

**The live pool:** native ETH / USDG, fee 3000, tick spacing 60, on Robinhood Chain's own Uniswap v4
PoolManager (`0x8366a39c…`). Pool id
`0x17fbcda00d5252905f0a63d2527601990cd5759939c22eb682b220a9c1505f42`.

Its rule: swaps under 0.0001 ETH are open; anything larger requires an ACCREDITED attestation.
Liquidity is ungated, and withdrawals can never be blocked.

## The demonstration

Every line below is a live mainnet read on chain 4663.

**Before the attestation** — a wallet with no credential attempts a 1 ETH swap:

```
checkAccess(pool, 0xB469…6d68, swap, 1 ETH) → 0  (DENIED)
minimumLevel(pool, swap)                    → 2  (ACCREDITED)
```

**The operator attests that wallet** at tier 2:
[`0xf164ec13819e0e913e95b1a086ba2243a295092ff21768bb47c69149391f071f`](https://robinhoodchain.blockscout.com/tx/0xf164ec13819e0e913e95b1a086ba2243a295092ff21768bb47c69149391f071f)

**After:**

```
checkAccess(pool, 0xB469…6d68, swap, 1 ETH) → 2  (ACCREDITED) → allowed
checkAccess(pool, 0x…dEaD,     swap, 1 ETH) → 0  (DENIED)     → still denied
```

And the rule is proportionate, not a blanket ban — the same unattested wallet trading below the
pool's limit:

```
checkAccess(pool, wallet, swap, 0.00001 ETH) → allowed
```

Anyone can reproduce all four reads with `cast call` against
`https://rpc.mainnet.chain.robinhood.com`.

## Why the design suits this chain

- **No dependency on Base's identity infrastructure.** The operator records its own KYC results
  on-chain through `SelfAttestationProvider`, so the same stack works on any EVM chain.
- **The issuer stays in control.** Whoever registers a pool becomes its admin, recorded on the hook
  in the `PoolPolicySet` event. Lexifi cannot change an issuer's rules, pause a pool or touch funds.
  The configuration store has no global owner by design.
- **Fail closed, never fail open.** An unconfigured pool denies everyone.
- **Exits are never blocked.** Only swaps and new liquidity are gated, so a wallet that loses its
  credential can still withdraw.
- **Every decision is auditable.** Passes and denials both emit events, which is what a regulator
  asks for and what a frontend check can never provide.

## Getting an issuer started takes 15 minutes

`guide/` in the repository holds a step-by-step runbook and a one-command script. An issuer whose
treasury is in a Safe never touches a private key: `guide/SafeBatch.s.sol` produces a Safe
Transaction Builder file that their existing signers approve, and the Safe becomes the pool admin.

The whole deploy on Robinhood Chain cost under 0.001 ETH.

## Status, stated plainly

- Live and enforcing on Robinhood Chain mainnet and on Base mainnet (9 contracts, in Uniswap's
  official hook registry).
- 162 Foundry tests, CI green, MIT licensed, every deployed contract reproducible from source.
- **No third-party audit yet.** An internal policy audit in September 2026 found three issues; all
  three are fixed and live in the V3 policies.
- **No external issuer in production yet.** This deployment is the reference implementation an
  issuer can copy.

## Links

- Code: https://github.com/Gomathi1806/lexifi-contracts
- 15-minute issuer guide: https://github.com/Gomathi1806/lexifi-contracts/tree/main/guide
- Robinhood Chain runbook: `docs/ROBINHOOD-DEPLOY.md`
- Uniswap hook registry entry (Base):
  https://github.com/Uniswap/hooklist/blob/main/hooks/base/0xfe92de69d2dddcac2f864c4cf84e8ad5e17d2880.json
- Dashboard: https://lexifiio.vercel.app
- SDK: https://github.com/Gomathi1806/lexifi-sdk (chain 4663 included)

Built by Gomathi Thayumanasundaram (NEWZIE.TECH LIMITED, trading as Lexifi), Uniswap Hook Incubator
alum.
