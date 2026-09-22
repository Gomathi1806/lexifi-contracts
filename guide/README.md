# Run a compliant Uniswap v4 pool in 15 minutes

A step-by-step guide for issuers and venues who want a Base pool where **only eligible wallets can
trade**, enforced by the pool itself rather than by a frontend.

Everything below happens from **your** address. You create the pool, you become its admin, and only
you can change its rules afterwards. Lexifi cannot change your rules, cannot pause your pool and
cannot touch your funds or your users'.

- **Time:** about 15 minutes
- **Cost:** about 455,000 gas for all three transactions, under a cent at Base's usual gas price
- **Price:** free, MIT-licensed, no fees

[![Watch the demo](https://img.youtube.com/vi/cnuJ0m1bC7g/hqdefault.jpg)](https://youtu.be/cnuJ0m1bC7g)

*2-minute demo: Lexifi enforcing compliance through a venue adapter (Aqua0 integration).*

---

## What you get

| | |
|---|---|
| Every swap and liquidity addition | checked against your rules, inside the pool contract |
| A wallet that doesn't qualify | the transaction reverts, and no frontend can route around it |
| Withdrawals | never blocked, including for wallets that fail the check |
| Every decision | an on-chain event, pass or fail, that you can export as an audit trail |
| A pool with no rules set | denies everyone: it fails closed, never open |

Two rule types are live today:

- **Regional** — jurisdiction rules. Require a verified country attestation, an account
  attestation, or a minimum verification level, separately for swaps and for liquidity.
- **Threshold** — rules by trade size. Small trades stay open, larger ones need verification.

On Base, identity comes from **Coinbase Verifications** (EAS attestations). On chains where those
don't exist, an operator-run provider records its own KYC results on-chain instead.

---

## Before you start

You need three things:

1. **[Foundry](https://getfoundry.sh)**. Install it with:
   ```bash
   curl -L https://foundry.paradigm.xyz | bash && foundryup
   ```
2. **A funded Base wallet.** A few dollars of ETH on Base covers the gas. Use a fresh deployer key,
   not your treasury key.
3. **Your two token addresses**, for example your token and USDC
   (`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` on Base).

> **Try it on Base Sepolia first** if you'd rather not touch mainnet. The steps are identical; only
> the RPC URL and the contract addresses change. Ask us for the testnet addresses.

---

## Step 1 — Get the code (5 minutes)

```bash
git clone https://github.com/Gomathi1806/lexifi-contracts
cd lexifi-contracts
forge install
forge build
```

**Checkpoint:** `forge build` ends with `Compiler run successful`.

## Step 2 — Describe your pool (5 minutes)

```bash
cp guide/env.example .env
```

> **Already have a `.env` in this repo?** Don't overwrite it. Append instead, so your existing keys
> survive: `cat guide/env.example >> .env`

Open `.env` and fill it in:

| Field | What to put |
|---|---|
| `PRIVATE_KEY` | **Optional.** Leave it out and sign with a hardware wallet or keystore instead — see step 3. |
| `RPC_URL` | `https://mainnet.base.org`, or your own provider |
| `CURRENCY0`, `CURRENCY1` | Your two tokens, sorted so that `CURRENCY0 < CURRENCY1` as numbers. Native ETH is the zero address. |
| `FEE`, `TICK_SPACING` | Standard Uniswap values, e.g. `3000` and `60` |
| `SQRT_PRICE_X96` | Your starting price. The default is 1:1. |
| `POLICY` | `regional` or `threshold` |
| `MIN_SWAP_LEVEL`, `MIN_LP_LEVEL` | `0` denied · `1` retail (basic KYC) · `2` accredited · `3` institutional |

**Two worked examples:**

*Only wallets with a verified country may trade, and the same to provide liquidity:*
```bash
POLICY=regional
REQUIRE_COUNTRY=true
MIN_SWAP_LEVEL=2
MIN_LP_LEVEL=2
```

*Trades under 0.0001 ETH are open, anything larger needs basic KYC:*
```bash
POLICY=threshold
NO_KYC_LIMIT=100000000000000
MIN_SWAP_LEVEL=1
```

**Checkpoint:** `CURRENCY0` sorts below `CURRENCY1`. If it doesn't, swap the two and invert your
price.

## Step 3 — Create the pool (2 minutes)

### Your treasury is in a Safe? Skip the command line

Generate a Safe Transaction Builder file — this reads your `.env`, needs no key, no keystore and no
RPC, and only encodes calldata:

```bash
forge script guide/SafeBatch.s.sol
```

It writes `guide/safe-batch.json`. In your Safe: **Apps → Transaction Builder → Load batch**, check
the three calls, and sign with your normal signers. **The Safe becomes the pool admin**, so
changing the pool's rules later takes the same signatures as moving treasury funds.

Ask us and we'll generate the file for you — send your token pair, fee tier and the rule you want.

### Or run it yourself



**You do not need to put a private key anywhere.** Pick whichever signer you already trust:

*Hardware wallet (Ledger). The key never leaves the device, and you approve each transaction on
it:*
```bash
forge script guide/PilotPool.s.sol --rpc-url $RPC_URL --ledger --sender <YOUR_ADDRESS> --broadcast
```

*Encrypted keystore. Import once, then unlock with a password each run — nothing is ever stored in
plain text:*
```bash
cast wallet import pool-admin --interactive          # once
forge script guide/PilotPool.s.sol --rpc-url $RPC_URL --account pool-admin --sender <YOUR_ADDRESS> --broadcast
```

*Or, if you prefer, a `PRIVATE_KEY` in `.env` — best kept to a throwaway deployer wallet:*
```bash
forge script guide/PilotPool.s.sol --rpc-url $RPC_URL --broadcast
```

The script does three things, all from your address:

1. **`PoolManager.initialize`** — creates the pool with LexifiHook attached.
2. **`LexifiHook.setPoolPolicy`** — makes your address the pool's admin and selects the rule type.
   This emits `PoolPolicySet(poolId, policy, name, version, poolCreator)`, which records you as the
   admin permanently.
3. **Writes your rules** to the config registry, where only your address can change them.

**Checkpoint:** the output prints your **pool id**. Save it.

## Step 4 — Verify it yourself (2 minutes)

```bash
cast call 0xfE92DE69d2dDdcAc2f864C4cF84e8aD5E17D2880 \
  "poolAdmin(bytes32)(address)" <YOUR_POOL_ID> \
  --rpc-url https://mainnet.base.org
```

**Checkpoint:** your own address comes back, not ours. Anyone can run this check, and the
`PoolPolicySet` event shows the same thing in the block explorer.

## Step 5 — Use the pool

1. **Add liquidity** as usual, through the Uniswap position manager or your own router.
2. **Try a swap from a wallet that doesn't meet your rules.** It reverts, and a
   `ComplianceCheckFailed` event records why.
3. **Try one from a wallet that does.** It goes through, and `ComplianceCheckPassed` records the
   level that was checked.

That pass-and-fail pair is the demonstration worth showing your compliance team.

---

## Troubleshooting

| What you see | What it means |
|---|---|
| `environment variable "CURRENCY0" not found` | Your `.env` is missing the pool fields. Run `cat guide/env.example >> .env` and fill them in. |
| `Error: Could not instantiate forked environment` or a connection refused | You left out `--rpc-url`. Without it, Foundry looks for a node on `localhost`. |
| `lack of funds (0) for max fee` | The wallet has no ETH on Base. Fund it with about 0.001 ETH; the three transactions cost roughly a cent. |
| `CURRENCY0 must sort below CURRENCY1` | Swap the two addresses and invert your starting price. |
| Reverts on `initialize` | The pool already exists. Set `SKIP_INITIALIZE=true` and run again to attach a policy to it. |
| `NotPoolAdmin` | Someone else already claimed this exact pool key. Change the fee or tick spacing to get a different pool, then re-run. |
| Every swap is denied | The pool has no rules yet, and unconfigured pools fail closed. Check that step 3 finished. |
| A wallet you expect to pass is denied | It has no Coinbase Verification attestation on Base. Check it in the dashboard, or lower `MIN_SWAP_LEVEL`. |
| `stale nonce` from the public RPC | Pass `--nonce` explicitly, or use your own RPC provider. |

### Rehearse it without spending anything

Run the whole thing against a local fork of Base first. It uses the real deployed contracts, at
real current state, with test ETH:

```bash
anvil --fork-url https://mainnet.base.org      # in one terminal
forge script guide/PilotPool.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Your pool id and admin come out exactly as they would on mainnet.

---

## Live contracts (Base mainnet, chainId 8453)

| Contract | Address |
|---|---|
| LexifiHook | `0xfE92DE69d2dDdcAc2f864C4cF84e8aD5E17D2880` |
| LexifiPolicyConfig (rule storage) | `0x9E005c201AEe5Db3c67b3658Cc18723dfDEe42E1` |
| RegionalPolicyV3 | `0x5309C741094e8901f9D2Ad1f31DC560006542a82` |
| ThresholdPolicy | `0x75f4913F53B694fDda95E49456D163Ca7AEf4199` |
| InstitutionalPolicyV3 | `0xdA93C63212CF41dB3680319B3839f254aC319177` |
| PoolManager (Uniswap) | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |

All source-verified on BaseScan, Blockscout and Sourcify. 162 tests. LexifiHook is listed in
[Uniswap's hook registry](https://github.com/Uniswap/hooklist).

---

## Questions we get asked

**Can Lexifi change or pause my pool?**
No. The admin recorded on the hook is the only address that can change the policy, and the rule
storage has no global owner by design.

**What happens to a user who can no longer pass the check?**
They can always withdraw. Only swaps and new liquidity are gated, never exits.

**Has it been audited?**
Not by a third party yet. An internal policy audit in September 2026 found three issues, all fixed
and live in the V3 policies. Start with a small pilot pool.

**What about Uniswap's Permissioned Pools?**
`LexifiAllowlistChecker` implements `IAllowlistChecker` for that path, over the same rules.

**Do I have to hand over a private key?**
No, in any of the three paths. A Safe batch is signed by your existing signers; `--ledger` keeps the
key on the device; `--account` unlocks an encrypted keystore with a password. Nothing about your
wallet reaches us in any case.

**Can I use my own rules?**
Yes. The hook accepts any contract implementing `ILexifiPolicy`, including one you write.

**What does it cost?**
Nothing. The contracts are MIT-licensed and take no fee. We charge for operated services such as
the dashboard, policy management and audit reporting.

---

Questions, or want us to set it up with you on a call?
Open an issue on [this repo](https://github.com/Gomathi1806/lexifi-contracts/issues), or see the
dashboard at [lexifiio.vercel.app](https://lexifiio.vercel.app).
