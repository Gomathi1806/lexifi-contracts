# Robinhood Chain deploy runbook (chainId 4663)

Lexifi's Base configuration cannot be copied to Robinhood Chain: the identity source it depends on
does not exist there. This runbook uses `SelfAttestationProvider` instead, where the operator
records its own KYC results on-chain.

Every step below was rehearsed against a **fork of Robinhood Chain mainnet** on 2026-09-23, from
the policy stack through to a gated pool. Only the real broadcast is left.

## What is actually on chain 4663 (probed 2026-09-23)

| Contract | Address | Status |
|---|---|---|
| Uniswap v4 PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` | live, 48 KB |
| PositionManager | `0x58daec3116aae6d93017baaea7749052e8a04fa7` | live |
| Universal Router | `0x8876789976decbfcbbbe364623c63652db8c0904` | live |
| StateView | `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b` | live |
| Quoter | `0x8dc178efb8111bb0973dd9d722ebeff267c98f94` | live |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | live |
| CREATE2 deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | live — needed for hook salt mining |
| Safe 1.4.1 singleton + proxy factory + MultiSend | canonical addresses | live |
| **EAS predeploy** `0x4200…0021` | — | **no code** |
| **Coinbase EAS indexer / attester** | — | **no code** |

So `CoinbaseEASProvider` would deny every address here, and the Base Safe
`0x17ae…4B7e` does not exist on this chain either — a new owner has to be set up.

Gas price at the time of probing: about 0.052 gwei.

## Prerequisites

1. **A fresh throwaway deployer key**, funded with a small amount of ETH on 4663. Never a key used
   on another chain.
2. **An owner address on 4663** for the owner-controlled contracts. Either a new Safe deployed
   through the canonical 1.4.1 factory (the contracts are there), or an EOA you control while the
   deploy is a pilot. It must not be the deployer.
3. RPC: `https://rpc.mainnet.chain.robinhood.com`

## Step 1 — Policy stack

```bash
PRIVATE_KEY=<throwaway> OWNER=<owner> \
forge script script/DeployRobinhood.s.sol \
  --rpc-url https://rpc.mainnet.chain.robinhood.com --broadcast
```

Deploys, in one transaction batch: `SelfAttestationProvider`, `LexifiPolicyConfig`,
`RegionalPolicyV3`, `InstitutionalPolicyV3`, `ThresholdPolicy`. Record every address.

## Step 2 — Mine the hook salt

The hook's address has to carry its permission bits, so it is deployed through CREATE2 at a mined
address. This reads nothing from the chain and needs no key:

```bash
POOL_MANAGER=0x8366a39cc670b4001a1121b8f6a443a643e40951 OWNER=<owner> \
forge script script/MineSalt.s.sol
```

It prints a salt and the address the hook will land on. The salt depends on the owner address, so
re-mine if the owner changes. In the rehearsal a salt was found within the first 36,000 candidates,
in a few seconds.

## Step 3 — Deploy the hook

```bash
PRIVATE_KEY=<throwaway> POOL_MANAGER=0x8366a39cc670b4001a1121b8f6a443a643e40951 \
OWNER=<owner> HOOK_SALT=<from step 2> \
forge script script/DeployHook.s.sol \
  --rpc-url https://rpc.mainnet.chain.robinhood.com --broadcast
```

The script refuses to broadcast unless the predicted address carries exactly
`beforeInitialize | beforeAddLiquidity | beforeSwap`.

## Step 4 — Create a gated pool

```bash
KEY="(<currency0>,<currency1>,3000,60,<hook>)"
cast send <poolManager> "initialize((address,address,uint24,int24,address),uint160)" "$KEY" <sqrtPriceX96> --private-key <key> --rpc-url <rpc>
cast send <hook> "setPoolPolicy((address,address,uint24,int24,address),address)" "$KEY" <thresholdPolicy> --private-key <key> --rpc-url <rpc>
cast send <thresholdPolicy> "setPoolConfig(bytes32,uint256,uint256,uint8,uint8)" <poolId> 100000000000000 1000000000000000000 0 2 --private-key <key> --rpc-url <rpc>
```

The pool id is `keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks))`.

## Step 5 — Attest a wallet and show the gate

From the **owner** address:

```bash
cast send <selfAttestationProvider> "attest(address,uint256,uint256)" <wallet> 2 <expiry> --private-key <ownerKey> --rpc-url <rpc>
```

Then read the gate, which is the demonstration worth recording:

```bash
cast call <thresholdPolicy> "checkAccess(bytes32,address,uint8,uint256)" <poolId> <wallet> 0 1000000000000000000 --rpc-url <rpc>
cast call <thresholdPolicy> "minimumLevel(bytes32,uint8)(uint8)" <poolId> 0 --rpc-url <rpc>
```

**Rehearsal result on the fork:** before attestation the wallet read `0` (DENIED) against a required
level of `2`; after the operator attested it at tier 2 it read `2`, which meets the requirement. The
pool admin came back as the deploying address, not Lexifi.

## Step 6 — Afterwards

- Add the 4663 addresses to `lexifi-sdk/src/addresses.ts`, EIP-55 checksummed.
- Verify the contracts on `robinhoodchain.blockscout.com`.
- `LexifiComplianceAdapter` and `LexifiAllowlistChecker` deploy through
  `script/DeployAllowlistChecker.s.sol`, which takes its addresses from the environment.
