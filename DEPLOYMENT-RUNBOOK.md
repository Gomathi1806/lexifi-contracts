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

## Deployed-address log (fill in as you go)

| Contract | v2 address (Base mainnet) |
|---|---|
| LexifiHook | |
| CoinbaseEASProvider | |
| ThresholdPolicy | |
| RegionalPolicy | |
| InstitutionalPolicy | |
