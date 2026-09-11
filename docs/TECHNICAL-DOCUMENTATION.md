# Lexifi Technical Documentation

**Pool-Level Compliance Infrastructure for Uniswap V4**
Version 2.0 | September 2026 — reflects Base mainnet as of 2026-09-11

---

## Table of Contents

1. Overview
2. System Architecture
3. Contract Reference
4. Execution Flows
5. Access Control Model
6. Compliance Tiers
7. Policy Templates
8. Verification Providers
9. Event Specification (Audit Trail)
10. Deployment Details
11. Security Model
12. Integration Guide
13. Test Coverage
14. Known Limitations

---

## 1. Overview

### What is Lexifi?

Lexifi is a B2B compliance infrastructure layer for Uniswap V4. It provides a single shared hook contract (`LexifiHook`) that enables any DEX operator, RWA platform, or asset issuer to launch liquidity pools with per-pool configurable compliance enforcement.

### Problem Statement

DeFi protocols that want to serve institutional capital or comply with regulations (EU MiCA, US broker-dealer rules) must enforce identity verification on their pools. Building this from scratch is risky, expensive, and non-interoperable. Each DEX reinvents the wheel.

### Solution

Lexifi provides:
- A shared hook deployed once per chain
- Three policy templates (Threshold, Regional, Institutional), internally reviewed; there has been no third-party audit yet (§11)
- A standard verification provider interface, with two providers live: Coinbase Verifications via EAS, and the operator's own KYC through `SelfAttestationProvider`
- Immutable on-chain audit trails for every compliance check
- A TypeScript SDK for frontend integration

### Key Invariants

1. **removeLiquidity is NEVER blocked.** Users can always withdraw funds regardless of compliance status. This is enforced at the CREATE2 address level — the `BEFORE_REMOVE_LIQUIDITY` permission bit is `false` and cannot be changed.

2. **Compliance checks are atomic with V4 flash accounting.** If a check fails mid-transaction, the entire `PoolManager.unlock()` reverts. No tokens move.

3. **Fail-safe to DENIED.** If any external call in the verification chain fails, users are denied — never falsely approved.

4. **Zero custom accounting.** The hook returns `ZERO_DELTA` and fee override `0`. No swap math is modified.

---

## 2. System Architecture

### Contract Dependency Graph

```
                    ┌──────────────────────┐
                    │  Uniswap V4          │
                    │  PoolManager         │
                    │  (Base Network)      │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │  LexifiHook          │
                    │  (IHooks)            │
                    │                      │
                    │  beforeSwap()        │
                    │  beforeAddLiquidity()│
                    │  beforeInitialize()  │
                    │                      │
                    │  State:              │
                    │  poolPolicy[PoolId]  │
                    │  poolAdmin[PoolId]   │
                    │  approvedPolicies[]  │
                    └──────────┬───────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                 │
    ┌─────────▼──────┐ ┌──────▼───────┐ ┌──────▼──────────┐
    │ ThresholdPolicy│ │RegionalPolicy│ │InstitutionalPol.│
    │ (ILexifiPolicy)│ │(ILexifiPolicy)│ │(ILexifiPolicy) │
    └────────┬───────┘ └──────┬───────┘ └──────┬──────────┘
             │                │                 │
             └────────────────┼─────────────────┘
                              │
                    ┌─────────▼──────────┐
                    │CoinbaseEASProvider │
                    │(IVerificationProv.)│
                    └─────────┬──────────┘
                              │
                    ┌─────────▼──────────┐
                    │  EAS + Indexer     │
                    │  (Base L2)         │
                    │  Coinbase Attester │
                    └────────────────────┘
```

### File Structure

```
contracts/src/
├── LexifiHook.sol                          # Core hook (270 lines)
├── interfaces/
│   ├── ILexifiPolicy.sol                   # Policy interface (45 lines)
│   └── IVerificationProvider.sol           # Provider interface (35 lines)
├── libraries/
│   └── LexifiEvents.sol                    # Audit events (65 lines)
└── policies/
    ├── CoinbaseEASProvider.sol             # Coinbase EAS integration (120 lines)
    ├── ThresholdPolicy.sol                 # Amount-based compliance (165 lines)
    ├── RegionalPolicy.sol                  # Geographic compliance (110 lines)
    └── InstitutionalPolicy.sol            # Multi-provider N-of-M (120 lines)

contracts/test/
├── LexifiHook.t.sol                        # 29 integration tests
├── ThresholdPolicy.t.sol                   # 20 unit tests
├── InstitutionalPolicy.t.sol              # 9 unit tests
└── mocks/
    ├── MockVerificationProvider.sol
    └── MockPoolManager.sol
```

---

## 3. Contract Reference

### 3.1 LexifiHook.sol

**Purpose:** Core hook contract. Implements `IHooks`. Routes compliance checks to per-pool policy contracts.

**Inheritance:** `IHooks` (from v4-core)

**State Variables:**

| Variable | Type | Visibility | Description |
|----------|------|------------|-------------|
| `poolManager` | `IPoolManager` | `public immutable` | Uniswap V4 PoolManager reference |
| `poolPolicy` | `mapping(PoolId => address)` | `public` | Policy contract assigned to each pool |
| `poolAdmin` | `mapping(PoolId => address)` | `public` | Admin address for each pool's compliance config |
| `isCompliancePool` | `mapping(PoolId => bool)` | `public` | Whether a pool has compliance enabled |
| `owner` | `address` | `public` | Lexifi global owner (can approve/revoke policies) |
| `approvedPolicies` | `mapping(address => bool)` | `public` | Owner-approved policy contracts, enforced only while `requireApproval` is on |
| `requireApproval` | `bool` | `public` | Whether only approved policies can be registered |
| `totalChecks` | `uint256` | `public` | Counter of all compliance checks performed |
| `totalPools` | `uint256` | `public` | Counter of pools with compliance registered |

**External Functions:**

| Function | Access | Mutability | Description |
|----------|--------|------------|-------------|
| `beforeInitialize(address, PoolKey, uint160)` | onlyPoolManager | nonpayable | No-op. Returns selector. Policy registered via `setPoolPolicy`. |
| `beforeSwap(address, PoolKey, SwapParams, bytes)` | onlyPoolManager | nonpayable | Core enforcement. Calls `_enforceCompliance` for compliance pools. |
| `beforeAddLiquidity(address, PoolKey, ModifyLiquidityParams, bytes)` | onlyPoolManager | nonpayable | Enforces compliance for LP deposits. |
| `afterInitialize(...)` | onlyPoolManager | nonpayable | Passthrough. Returns selector. |
| `beforeRemoveLiquidity(...)` | onlyPoolManager | nonpayable | Passthrough. Always allows exit. |
| `afterAddLiquidity(...)` | onlyPoolManager | nonpayable | Passthrough. Returns (selector, ZERO_DELTA). |
| `afterRemoveLiquidity(...)` | onlyPoolManager | nonpayable | Passthrough. Returns (selector, ZERO_DELTA). |
| `afterSwap(...)` | onlyPoolManager | nonpayable | Passthrough. Returns (selector, 0). |
| `beforeDonate(...)` | onlyPoolManager | nonpayable | Passthrough. Returns selector. |
| `afterDonate(...)` | onlyPoolManager | nonpayable | Passthrough. Returns selector. |
| `setPoolPolicy(PoolKey, address)` | public | nonpayable | Register/update policy for a pool. First caller becomes admin. |
| `transferPoolAdmin(PoolKey, address)` | pool admin only | nonpayable | Transfer pool admin rights. |
| `approvePolicy(address)` | owner only | nonpayable | Whitelist a policy contract. |
| `revokePolicy(address)` | owner only | nonpayable | Remove policy from whitelist. |
| `setRequireApproval(bool)` | owner only | nonpayable | Toggle approval requirement. |
| `transferOwnership(address)` | owner only | nonpayable | Transfer Lexifi ownership. |
| `checkUserCompliance(PoolKey, address, uint8, uint256)` | public | view | Read-only compliance check. |
| `getPoolInfo(PoolKey)` | public | view | Get pool's policy, admin, and compliance status. |

**Internal Functions:**

| Function | Description |
|----------|-------------|
| `_enforceCompliance(PoolId, address, uint8, uint256)` | Core engine. Calls policy, compares tiers, emits events, reverts or allows. |

**Custom Errors:**

| Error | Parameters | Trigger |
|-------|------------|---------|
| `ComplianceDenied` | `(address user, uint8 required, uint8 actual, string reason)` | User's tier < pool's minimum |
| `PolicyNotApproved` | `(address policy)` | requireApproval=true and policy not whitelisted |
| `InvalidPolicy` | `(address policy)` | Zero address or contract doesn't implement ILexifiPolicy |
| `NotPoolAdmin` | `(address caller, PoolId poolId)` | Non-admin tries to modify pool config |
| `OnlyOwner` | none | Non-owner calls owner function |
| `OnlyPoolManager` | none | Non-PoolManager calls hook callback |

**Hook Permission Bits:**

```
Address: 0x...2880
Binary:  0010 1000 1000 0000

Bit 13 (0x2000) = BEFORE_INITIALIZE     ✓ ON
Bit 11 (0x0800) = BEFORE_ADD_LIQUIDITY   ✓ ON
Bit 7  (0x0080) = BEFORE_SWAP            ✓ ON
All other bits = OFF
```

### 3.2 ILexifiPolicy.sol

**Purpose:** Interface that all compliance policy contracts must implement.

**Enum:**

```solidity
enum AccessLevel {
    DENIED,        // 0 — Cannot interact
    RETAIL,        // 1 — Basic KYC (Coinbase Verified Account)
    ACCREDITED,    // 2 — Enhanced (Account + Country)
    INSTITUTIONAL  // 3 — Full institutional (Business verified)
}
```

**Functions:**

| Function | Returns | Description |
|----------|---------|-------------|
| `checkAccess(PoolId, address, uint8, uint256)` | `(AccessLevel, string)` | Check user's access for a pool/operation/amount. Returns level and denial reason. |
| `minimumLevel(PoolId, uint8)` | `AccessLevel` | Minimum tier required for a specific operation on a pool. |
| `policyName()` | `string` | Human-readable policy name. |
| `policyVersion()` | `uint256` | Policy version number. |

**Operation codes:**
- `0` = Swap
- `1` = Add Liquidity
- `2` = Remove Liquidity (should never be called — hook doesn't enforce)

### 3.3 IVerificationProvider.sol

**Purpose:** Standardized interface for identity/compliance verification providers.

**Struct:**

```solidity
struct VerificationResult {
    bool verified;          // Passed verification?
    uint256 tier;           // Provider-specific tier (maps to AccessLevel)
    uint256 expiry;         // Expiration timestamp (0 = no expiry)
    bytes32 attestationId;  // On-chain attestation reference
    string providerName;    // e.g. "coinbase", "worldcoin"
}
```

**Functions:**

| Function | Returns | Description |
|----------|---------|-------------|
| `verify(address)` | `VerificationResult` | Check user's verification status. |
| `providerId()` | `bytes32` | Unique provider identifier hash. |
| `providerName()` | `string` | Human-readable name. |
| `supportsType(bytes32)` | `bool` | Whether provider supports a verification type (KYC, COUNTRY, etc.). |

### 3.4 LexifiEvents.sol

**Purpose:** Library of standardized events for on-chain audit trails.

**Events:**

| Event | Indexed Fields | Data Fields | When Emitted |
|-------|---------------|-------------|--------------|
| `PoolPolicySet` | poolId, policyContract, poolCreator | policyName, policyVersion | New pool policy registered |
| `ComplianceCheckPassed` | poolId, user | operation, accessLevel, requiredLevel, amount, timestamp | User passes compliance |
| `ComplianceCheckFailed` | poolId, user | operation, accessLevel, requiredLevel, reason, timestamp | User fails compliance (before revert) |
| `PoolPolicyUpdated` | poolId, oldPolicy, newPolicy | updatedBy | Pool policy changed |
| `AuditRecord` | txHash, poolId, user | operation, passed, amount, blockNumber, timestamp | Every compliance check (pass or fail) |
| `ProviderRegistered` | providerId, providerAddress | providerName | New provider added |
| `ProviderRevoked` | providerId, providerAddress | reason | Provider removed |

### 3.5 CoinbaseEASProvider.sol

**Purpose:** Reads Coinbase Verifications from EAS on Base. Maps attestations to compliance tiers.

**External interfaces used:**

```solidity
interface IEASIndexer {
    function getAttestationUid(address recipient, bytes32 schemaId) external view returns (bytes32);
}

interface IEAS {
    struct Attestation { bytes32 uid; bytes32 schema; uint64 time; uint64 expirationTime;
        uint64 revocationTime; bytes32 refUID; address attester; address recipient; bool revocable; bytes data; }
    function getAttestation(bytes32 uid) external view returns (Attestation memory);
}
```

**Immutable state:**

| Variable | Type | Description |
|----------|------|-------------|
| `eas` | `IEAS` | EAS contract (0x4200...0021 on Base) |
| `indexer` | `IEASIndexer` | Coinbase EAS Indexer (0x2c7e...619C) |
| `coinbaseAttester` | `address` | Coinbase's attester address (0x3574...30Dd7EE) |

**Schema constants:**

| Schema | Hash | Tier |
|--------|------|------|
| `SCHEMA_ACCOUNT` | `0xf8b05c79...0f0de9` | Tier 1 (RETAIL) |
| `SCHEMA_COUNTRY` | `0x18019016...01ca065` | Tier 2 (with Account) |
| `SCHEMA_BIZ_ACCOUNT` | `0xf82663c0...480abf3` | Tier 3 |
| `SCHEMA_BIZ_COUNTRY` | `0xf87445e6...21f6c80b` | Tier 3 |

**Tier mapping logic:**

```
Business Account OR Business Country → tier 3 (INSTITUTIONAL)
Account + Country                    → tier 2 (ACCREDITED)
Account only                         → tier 1 (RETAIL)
None                                 → tier 0 (DENIED)
```

**Attestation validation (in `_hasValidAttestation`):**
1. Query indexer for attestation UID
2. If UID is bytes32(0) → false
3. Read full attestation from EAS
4. Check `attester == coinbaseAttester`
5. Check `revocationTime == 0` (not revoked)
6. Check `expirationTime == 0 || expirationTime >= block.timestamp` (not expired)
7. All pass → true

### 3.6 ThresholdPolicy.sol

**Purpose:** Amount-based compliance. Configurable thresholds per pool.

**Per-pool config struct:**

```solidity
struct PoolConfig {
    uint256 noKycLimit;       // Below: no KYC needed
    uint256 enhancedLimit;    // Above: requires ACCREDITED
    AccessLevel lpMinimum;    // Minimum for liquidity providers
    AccessLevel swapMinimum;  // Minimum for any swap (floor)
    bool active;
}
```

**checkAccess logic for swaps (operation=0):**

```
1. Check manual override → return override tier
2. Get user tier from provider.verify()
3. If pool not configured → return INSTITUTIONAL (open)
4. If amount <= noKycLimit → return INSTITUTIONAL (anyone)
5. If amount > enhancedLimit AND user < ACCREDITED → return DENIED
6. If user < swapMinimum → return DENIED
7. Otherwise → return user's tier (pass)
```

**checkAccess logic for addLiquidity (operation=1):**

```
1-3. Same as above
4. If user < lpMinimum → return DENIED
5. Otherwise → return user's tier (pass)
```

### 3.7 RegionalPolicyV3.sol (live)

**Purpose:** Geographic and attestation-based compliance.
**Configuration:** stored in `LexifiPolicyConfig` (§3.9) under the family
`keccak256("lexifi.policy.regional")`, not in the policy.

```solidity
struct RegionConfig {
    bool requireCountryAttestation;
    bool requireAccountAttestation;
    AccessLevel minimumSwapLevel;
    AccessLevel minimumLpLevel;
    bool active;
}
```

- A required attestation the user lacks returns `DENIED`.
- A `minimumLpLevel` below `minimumSwapLevel` is raised to it at read time, so an address barred
  from swapping cannot acquire the asset by providing liquidity. `validateConfig(poolId)`
  reports whether that happened.
- A pool with no configuration fails closed: `checkAccess` returns `DENIED` and `minimumLevel`
  returns `INSTITUTIONAL`. Returning `DENIED` from both would pass the `>=` comparison, so both
  sides are needed.
- `policyVersion()` returns 3.

### 3.8 InstitutionalPolicyV3.sol (live)

**Purpose:** Multi-provider N-of-M verification.
**Configuration:** stored in `LexifiPolicyConfig` under `keccak256("lexifi.policy.institutional")`.

```solidity
struct InstitutionalConfig {
    address[] requiredProviders;
    uint256 minimumProviders;    // N of M
    AccessLevel minimumTier;
    bool active;
}
```

- Calls `verify()` on every provider and counts those returning `verified` at or above
  `minimumTier`.
- Fewer than `minimumProviders` passing returns `DENIED`.
- A `minimumProviders` above the provider count is lowered to that count, and a stored `0` is
  raised to `1`, so the policy can never become a no-op.
- Unconfigured pools fail closed, as in §3.7.

### 3.9 LexifiPolicyConfig.sol (live)

Shared per-pool configuration store for the V3 policies, keyed by `(family, poolId)`. The family
key is constant across logic versions, so a redeployed policy reads the same configuration with
no migration.

| Function | Caller | Purpose |
|----------|--------|---------|
| `setConfig(family, poolId, data)` | The pool's registry admin; the first writer becomes admin | Write one pool's configuration |
| `setConfigBatch(family, poolIds, datas)` | Same | Write several pools atomically |
| `clearConfig(family, poolId)` | Same | Remove configuration, which closes the pool under V3 |
| `transferPoolAdmin(family, poolId, newAdmin)` | Same | Hand over the admin role |
| `getConfig`, `isConfigured` | Anyone | Read |

The registry stores opaque bytes and never validates them; the policies normalise at read time.
It has no owner and no override.

### 3.10 SelfAttestationProvider.sol (live)

An `IVerificationProvider` fed by the operator's own KYC process: the operator records a tier for
each address, with an expiry, singly or in batches, and can revoke it. It has no external
dependencies, so it works on any chain (§8).

### 3.11 LexifiComplianceAdapter.sol (live)

Single-call entry point for third-party hooks and venues, implementing `ILexifiCompliance`:

```solidity
function checkCompliance(bytes32 poolId, address user, uint8 operation, uint256 amount)
    external view returns (bool allowed, uint8 userTier, uint8 requiredTier, string memory reason);
function hasPolicy(bytes32 poolId) external view returns (bool);
```

It reads the pool's policy from `LexifiHook` and applies the same comparison the hook enforces.
It has no owner; the hook address is fixed at deployment.

### 3.12 LexifiAllowlistChecker.sol (live)

The `IAllowlistChecker` implementation for Uniswap v4 Permissioned Pools. Uniswap's
`PermissionsAdapter` calls `checkAllowlist(account, token)` and receives `SWAP_ALLOWED` and
`LIQUIDITY_ALLOWED` flags.

- `bindToken(token, poolId, evaluationAmount, liquidityRequiresSwap)` maps a permissioned token
  to the Lexifi pool whose policy governs it. Uniswap's interface carries no amount, so each
  binding pins the notional the policy is evaluated at; `0` is rejected.
- `liquidityRequiresSwap` (on by default) withholds the liquidity flag from addresses denied the
  swap flag.
- It fails closed: an unbound token, a paused checker or a reverting policy all return `NONE`.
- `previewPermissions(account, token)` returns the reason behind the flags, for user-facing
  messages.

The Safe owns it. No tokens are bound on mainnet yet, so it currently denies every address.

### 3.13 RegionalPolicy.sol and InstitutionalPolicy.sol (retired)

The previous policy logic, which kept configuration in its own storage. The files in the
repository are logic v2 (`policyVersion()` = 2, audit fixes applied); logic v1, deployed from an
earlier revision, carried audit findings 2 and 3. No pool uses either (§10). They remain because
the tests use them as the reference the V3 migration is proven equivalent against, and because
they are the source of contracts still on-chain.

---

## 4. Execution Flows

### 4.1 Swap with Compliance

```
User → Router.swap()
  → PoolManager.unlock()
    → PoolManager calls LexifiHook.beforeSwap(sender, key, params, hookData)
      → Hook reads poolPolicy[poolId]
      → If isCompliancePool[poolId] == false:
          return (selector, ZERO_DELTA, 0)  // no compliance, allow
      → If isCompliancePool[poolId] == true:
          → _enforceCompliance(poolId, _resolveUser(sender), 0, |amountSpecified|)
            → policy.checkAccess(poolId, user, 0, amount)
              → provider.verify(user)
                → indexer.getAttestationUid(user, schema)
                → eas.getAttestation(uid)
                → return VerificationResult
              → Apply policy rules (threshold/regional/institutional)
              → return (AccessLevel, reason)
            → policy.minimumLevel(poolId, 0)
              → return AccessLevel
            → Compare: userLevel >= requiredLevel?
              → YES: emit ComplianceCheckPassed, emit AuditRecord
                     return (selector, ZERO_DELTA, 0)
              → NO:  emit ComplianceCheckFailed, emit AuditRecord
                     revert ComplianceDenied(user, required, actual, reason)
    → If beforeSwap returned selector:
        → Execute swap (PoolManager handles all accounting)
        → Call afterSwap (passthrough in Lexifi)
    → Settle balances
```

### 4.2 Policy Registration

```
DEX Operator → LexifiHook.setPoolPolicy(poolKey, policyAddress)
  → Compute poolId = keccak256(poolKey)
  → If poolAdmin[poolId] != 0 AND poolAdmin[poolId] != msg.sender:
      revert NotPoolAdmin
  → If policyAddress == address(0):
      revert InvalidPolicy
  → If requireApproval AND !approvedPolicies[policyAddress]:
      revert PolicyNotApproved
  → Try ILexifiPolicy(policyAddress).policyName():
      → If reverts: revert InvalidPolicy
  → poolPolicy[poolId] = policyAddress
  → poolAdmin[poolId] = msg.sender
  → If !isCompliancePool[poolId]:
      isCompliancePool[poolId] = true
      totalPools++
      emit PoolPolicySet(...)
  → Else:
      emit PoolPolicyUpdated(...)
```

### 4.3 Multi-Hop Swap (Flash Accounting Synergy)

```
User → Router.multiHopSwap(A→B→C)
  → PoolManager.unlock()
    → Hop 1: Pool A (WETH/USDC, ThresholdPolicy)
      → beforeSwap → checkAccess → user is RETAIL, amount $5k → PASS ✓
    → Hop 2: Pool B (USDC/RWA, InstitutionalPolicy)
      → beforeSwap → checkAccess → user is RETAIL, need INSTITUTIONAL → FAIL ✗
      → revert ComplianceDenied
    → Entire unlock() reverts
    → Flash accounting: ZERO tokens moved from Hop 1 or Hop 2
    → User's wallet unchanged
```

---

## 5. Access Control Model

### Three-Level Hierarchy

```
Level 1: Lexifi Owner (global)
  ├── approvePolicy / revokePolicy
  ├── setRequireApproval
  └── transferOwnership

Level 2: Pool Admin (per-pool)
  ├── setPoolPolicy (register/change policy)
  └── transferPoolAdmin

Level 3: PoolManager (protocol)
  └── All IHooks callbacks (beforeSwap, etc.)
```

### Permission Matrix

| Action | Lexifi Owner | Pool Admin | PoolManager | Anyone |
|--------|:---:|:---:|:---:|:---:|
| Approve/revoke policy | ✓ | | | |
| Toggle requireApproval | ✓ | | | |
| Register pool policy | | ✓ (first caller or existing admin) | | |
| Change pool policy | | ✓ | | |
| Transfer pool admin | | ✓ | | |
| beforeSwap/beforeAddLiquidity | | | ✓ | |
| checkUserCompliance (view) | | | | ✓ |
| getPoolInfo (view) | | | | ✓ |

---

## 6. Compliance Tiers

| Tier | Enum Value | Name | Coinbase EAS Requirement | Typical Use Case |
|------|:---:|------|--------------------------|------------------|
| 0 | `DENIED` | No Access | None | Unverified wallets |
| 1 | `RETAIL` | Basic KYC | Verified Account attestation | Retail trading above threshold |
| 2 | `ACCREDITED` | Enhanced | Account + Country attestation | Regulated markets, large trades |
| 3 | `INSTITUTIONAL` | Full | Business Account or Business Country | Security tokens, RWA, institutional pools |

---

## 7. Policy Templates

### ThresholdPolicy — Amount-Based Tiers

**Use case:** Retail-friendly DEX pools with graduated compliance.

**Example configuration:**

```
noKycLimit:    1,000 USDC — Below this, anyone can trade
enhancedLimit: 10,000 USDC — Above this, need ACCREDITED
swapMinimum:   RETAIL — Floor tier for any swap above noKycLimit
lpMinimum:     RETAIL — Floor tier for adding liquidity
```

**Behavior matrix:**

| User Tier | Trade < $1k | Trade $1k-$10k | Trade > $10k | Add Liquidity |
|-----------|:---:|:---:|:---:|:---:|
| DENIED (0) | ✓ Allow | ✗ Deny | ✗ Deny | ✗ Deny |
| RETAIL (1) | ✓ Allow | ✓ Allow | ✗ Deny | ✓ Allow |
| ACCREDITED (2) | ✓ Allow | ✓ Allow | ✓ Allow | ✓ Allow |
| INSTITUTIONAL (3) | ✓ Allow | ✓ Allow | ✓ Allow | ✓ Allow |

The liquidity column gates on tier alone and ignores the amount; see §14.

### RegionalPolicy — Geographic Compliance

**Use case:** EU MiCA-compliant pools, US accredited investor pools.

**Configuration options:**
- `requireCountryAttestation`: Must have country verification (tier >= 2)
- `requireAccountAttestation`: Must have account verification (tier >= 1)
- `minimumSwapLevel`: Floor tier for swaps
- `minimumLpLevel`: Floor tier for LPs
- Configuration lives in `LexifiPolicyConfig` (§3.9); a `minimumLpLevel` below `minimumSwapLevel` is raised to it at read time

### InstitutionalPolicy — Multi-Provider N-of-M

**Use case:** RWA pools, security tokens requiring multiple verification sources.

**Example:** Require both Coinbase Verifications and the operator's own KYC (2-of-2) at ACCREDITED or above, as two independent trust anchors.

**Execution:** Calls `verify()` on every configured provider and counts the passes. Fewer than `minimumProviders` passes returns `DENIED` (§3.8).

---

## 8. Verification Providers

### CoinbaseEASProvider (Live)

**Chain:** Base (L2)
**Protocol:** Ethereum Attestation Service (EAS)
**Data flow:** Provider → EAS Indexer → EAS Contract → Coinbase Attester verification

**Attestation validation checks:**
1. Attestation exists for user + schema
2. Attester is Coinbase (`0x357458739F90461b99789350868CD7CF330Dd7EE`)
3. Not revoked (`revocationTime == 0`)
4. Not expired (`expirationTime == 0 || expirationTime >= block.timestamp`)

**Error handling:** All external calls wrapped in try/catch. Any failure returns `tier=0, verified=false`. Fail-safe to DENIED.

**Ownership:** none. There is no owner function; the EAS, indexer and attester addresses are
fixed at deployment. If Coinbase ever rotates its attester, the provider has to be redeployed
and the policies re-pointed.

### SelfAttestationProvider (Live)

**Chain:** any EVM chain; no external dependencies.
**Model:** the operator verifies users off-chain with its own KYC process and records a tier for
each address on-chain, with an expiry. Supports batch attestation and revocation.

This is the provider to use off Base. Coinbase Verifications exist only on Base, so
`CoinbaseEASProvider` returns tier 0 on every other chain.

### Other providers

Any identity system that implements `IVerificationProvider` (`verify`, `providerId`,
`providerName`, `supportsType`) can be added without changing the hook or the policies.

---

## 9. Event Specification (Audit Trail)

### ComplianceCheckPassed

```solidity
event ComplianceCheckPassed(
    PoolId indexed poolId,      // Which pool
    address indexed user,       // Who was checked
    uint8 operation,            // 0=swap, 1=addLiquidity
    uint8 accessLevel,          // User's verified tier
    uint8 requiredLevel,        // Pool's minimum tier
    uint256 amount,             // Transaction amount
    uint256 timestamp           // block.timestamp
);
```

### ComplianceCheckFailed

```solidity
event ComplianceCheckFailed(
    PoolId indexed poolId,
    address indexed user,
    uint8 operation,
    uint8 accessLevel,
    uint8 requiredLevel,
    string reason,              // Human-readable denial reason
    uint256 timestamp
);
```

### AuditRecord

```solidity
event AuditRecord(
    bytes32 indexed txHash,     // Transaction hash
    PoolId indexed poolId,
    address indexed user,
    uint8 operation,
    bool passed,                // true=allowed, false=denied
    uint256 amount,
    uint256 blockNumber,
    uint256 timestamp
);
```

**Note:** Both `ComplianceCheckFailed` and its corresponding `AuditRecord` are emitted BEFORE the revert. Since the transaction reverts, these events are NOT persisted on-chain. They are visible only in trace/debug tools. The `ComplianceCheckPassed` and successful `AuditRecord` events ARE persisted.

---

## 10. Deployment Details

### Base Mainnet (Chain ID: 8453)

Canonical source: `lexifi-sdk/src/addresses.ts`. Confirmed on-chain 2026-09-11. For every
contract below, the runtime bytecode on Base matches this repository's build with immutables
masked, and for all but `LexifiComplianceAdapter` the metadata hash matches too.

| Contract | Address | Owner |
|----------|---------|-------|
| LexifiHook | `0xfE92DE69d2dDdcAc2f864C4cF84e8aD5E17D2880` | Safe |
| LexifiPolicyConfig | `0x9E005c201AEe5Db3c67b3658Cc18723dfDEe42E1` | none (per-pool admins) |
| RegionalPolicyV3 | `0x5309C741094e8901f9D2Ad1f31DC560006542a82` | Safe |
| InstitutionalPolicyV3 | `0xdA93C63212CF41dB3680319B3839f254aC319177` | Safe |
| ThresholdPolicy | `0x75f4913F53B694fDda95E49456D163Ca7AEf4199` | Safe |
| CoinbaseEASProvider | `0xb5DEC225A104A276671A765aba3890EC88A2ca27` | none |
| SelfAttestationProvider | `0x344E4917360F5b44680D097c5E4904Ac62c00483` | Safe |
| LexifiComplianceAdapter | `0xE59FB4347CA17Aa94BBD62eBB9921877B06b68eE` | none |
| LexifiAllowlistChecker | `0x3882cD541634b99DabB5443Dc0DC67Ba4eDe94bc` | Safe |

Safe `0x17ae269e27524E82F29ca76Cb39A151A90a34B7e`, 1-of-1, signer
`0x4122c8b8080c8960F52d3D1cCb3A8d85EFF1f039`. The hook's `requireApproval` is `false`.
`LexifiAllowlistChecker` binds no tokens, so it denies every address until the Safe calls
`bindToken`.

**Live pools**

| Pool | Pool ID | Policy |
|------|---------|--------|
| WETH/USDC, fee 3000, tick spacing 60 | `0x54545d84902d4f5864c9d3f5c14d7dd961c8218dd41fef3292c4eac636e8f424` | RegionalPolicyV3, config `(requireCountry=true, requireAccount=false, minSwap=ACCREDITED, minLp=ACCREDITED)` |
| ETH/TestToken (Phase 1 proof) | `0x49081a9762db094a03e395f3d38272a16b69c753c904d7e4dfd16bd09a47a718` | ThresholdPolicy |

Pool-admin rights for both pools (on the hook, in the registry for WETH/USDC, and in
ThresholdPolicy) were transferred to the Safe on 2026-09-11.

**Retired — still on-chain, do not use**

| What | Addresses | Why |
|------|-----------|-----|
| v1 generation | hook `0xb8ab…2880`, provider `0x9Da4…E1d7`, threshold `0x1074…2259`, regional `0x5568…F029`, institutional `0x3120…fC30`, zkPass `0x929E…b646` | Owner key `0x22bc…a621` compromised; the provider had EAS `recipient` and `attester` swapped, so every check returned tier 0 |
| v2 generation | hook `0x67a9…2880`, provider `0xF701…A7ea`, threshold `0x0b37…b74b`, regional `0xcF06…d6e2`, institutional `0xbe8a…88d5` | Owned by a Coinbase Smart Wallet BaseScan cannot drive; orphaned |
| Regional and Institutional policy, logic v1 | `0xA99A89Cd5A61e975fB11047D3ed455fCCad9A44F`, `0xaD09fc63080736b1dFC4048F3589C481225db5fb` | Audit findings 2 and 3 (§11); superseded by V3 on 2026-09-07 |
| Regional and Institutional policy, logic v2 | `0xf4f6af6ee5ff4a1bf712470e00fea2b6bafbf32c`, `0xaa3f1309219231091b606ca256771e51c3e9d822` | Carried the audit fixes, but V3 replaced them the same day before any pool used them |

**External dependencies on Base:**
| Contract | Address | Owner |
|----------|---------|-------|
| EAS | `0x4200000000000000000000000000000000000021` | Base L2 predeploy |
| EAS Indexer | `0x2c7eE1E5f416dfF40054c27A62f7B357C4E8619C` | Coinbase |
| Coinbase Attester | `0x357458739F90461b99789350868CD7CF330Dd7EE` | Coinbase |
| PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` | Uniswap |

### Base Sepolia (Chain ID: 84532)

| Contract | Address |
|----------|---------|
| LexifiHook | `0x5b814ad56562a9Ee47776A382C6aF678B07aa880` |
| CoinbaseEASProvider | `0xD40C35303FFF70E36A2Ea74fAC66de5D191bA6d8` |
| ThresholdPolicy | `0xB2228cd33A2E4004c0e14fe9510E93df1d3aC2b2` |
| InstitutionalPolicy | `0xe05d670802DF1a2FD0F5875439EFA40dfA1A5AEd` |

### Deployment Method

Hook deployed via **CREATE2** using the deterministic deployer at `0x4e59b44847b379578588920cA78FbF26c0B4956C`. Salt mined to produce address ending in `0x2880` (correct permission bits).

### Compiler Settings

```toml
solc_version = "0.8.26"
evm_version = "cancun"
optimizer = true
optimizer_runs = 200
via_ir = true
```

---

## 11. Security Model

### Threat Model

| Threat | Mitigation |
|--------|------------|
| Malicious policy contract (always approves) | `requireApproval` flag plus the owner's approved-policy list. Currently `requireApproval = false`. |
| Malicious policy contract (DoS via revert) | Pool admin can change policy via `setPoolPolicy` |
| Reentrancy via external call to policy | `onlyPoolManager` on all callbacks. PoolManager lock prevents re-entry. |
| EAS/Indexer unavailable | Provider try/catch returns tier=0 (DENIED). Fail-safe. |
| Pool admin key compromise | Admin can transfer to new address. Worst case: policy changed, not funds stolen. |
| Lexifi owner key compromise | Owner can only approve/revoke policies and toggle approval mode. Cannot access pool funds. |
| User identity spoofed through a router | The hook never reads `tx.origin`. It takes the user from `IMsgSender.msgSender()` only on routers the owner marked trusted; any other caller is treated as the user itself, so an unvetted router must hold its own verification. |
| Smart-contract wallets (Safe, ERC-4337) | Supported through trusted routers: `msgSender()` returns the account address. |
| Policy logic bug found after deployment | Policies are immutable. The fix is a new policy and re-pointed pools; V3 keeps configuration in `LexifiPolicyConfig`, so a redeploy needs no configuration migration. |
| Pool pointed at an unconfigured policy | V3 policies fail closed rather than open. |
| Fund trapping | Impossible. beforeRemoveLiquidity permission bit = false in CREATE2 address. |

### Audit Status

There has been no third-party audit. An internal review on 2026-09-04 found three issues, each
reproduced as a failing test before it was fixed:

| # | Finding | Resolution |
|---|---------|------------|
| 1 | RegionalPolicy accepted `minLp < minSwap`, reopening a liquidity path for addresses barred from swapping | V3 raises `minLp` to `minSwap` at read time; `validateConfig` reports it |
| 2 | RegionalPolicy's country and account attestation flags returned the user's real level instead of denying | V3 denies |
| 3 | InstitutionalPolicy's N-of-M quorum never gated: one passing provider cleared the user | V3 denies when fewer than `minimumProviders` pass |
| – | Unconfigured pools were open | V3 fails closed |

All fixes are live since 2026-09-07. The affected v1 contracts remain on-chain, since contracts
are immutable, but no pool uses them. Proofs of concept: `test/PolicyAsymmetryAudit.t.sol`.

### What the Hook CANNOT Do

- Cannot modify swap amounts or prices (returns ZERO_DELTA)
- Cannot take fees (returns fee override 0)
- Cannot prevent liquidity withdrawal (permission bit false)
- Cannot access or move user tokens
- Cannot modify pool state directly

### What the Hook CAN Do

- Allow or revert swap transactions
- Allow or revert addLiquidity transactions
- Emit events
- Increment a counter (totalChecks)

---

## 12. Integration Guide

### For DEX Developers (SDK)

```typescript
import { createPublicClient, http, parseUnits } from "viem";
import { base } from "viem/chains";
import { getDeployment, LexifiHookAbi, Operation } from "@lexifi/sdk";

const { hook } = getDeployment(8453);
const client = createPublicClient({ chain: base, transport: http() });

// The same check the hook enforces in beforeSwap, as a free read
const [allowed, userLevel, requiredLevel, reason] = await client.readContract({
  address: hook,
  abi: LexifiHookAbi,
  functionName: "checkUserCompliance",
  args: [poolKey, traderAddress, Operation.SWAP, parseUnits("5000", 18)],
});

if (!allowed) showVerificationPrompt(reason);
```

Install with `npm install @lexifi/sdk viem`, version 2.0.0 or later. Version 1.0.0 is a retired
v1-era build.

### For Pool Operators (on-chain)

For a Regional or Institutional (V3) policy, write the pool's configuration to
`LexifiPolicyConfig` first; the SDK's `encodeRegionalConfig` and `encodeInstitutionalConfig`
produce the bytes. A V3 policy denies every address on a pool it has no configuration for, so
pointing a live pool at it before writing configuration stops the pool trading.

```bash
# Register a policy on your pool. The first caller becomes the pool admin.
cast send $LEXIFI_HOOK \
  "setPoolPolicy((address,address,uint24,int24,address),address)" \
  "($TOKEN0,$TOKEN1,3000,60,$LEXIFI_HOOK)" \
  $POLICY \
  --rpc-url https://mainnet.base.org \
  --account pool-admin
```

---

## 13. Test Coverage

**162 tests across 9 suites, all passing** (`forge test`, 2026-09-11). CI runs the full suite on
every push (`.github/workflows/test.yml`). No RPC endpoint or key is needed.

| Suite | What it covers |
|-------|----------------|
| `LexifiHook.t.sol` | Policy registration (valid, invalid, admin-only, update), enforcement in `beforeSwap` and `beforeAddLiquidity`, `beforeRemoveLiquidity` always passing, the `onlyPoolManager` guard, views, owner functions, events |
| `ThresholdPolicy.t.sol` | Small, medium and large swaps for each tier, liquidity gating, minimum levels, configuration and access control |
| `InstitutionalPolicy.t.sol` | N-of-M quorum, asserted through the enforcement comparison |
| `SelfAttestationProvider.t.sol` | Operator attestations, expiry, batching and revocation |
| `PolicyAsymmetryAudit.t.sol` | The three audit findings, originally proofs of concept, now asserting the fixed behaviour |
| `PolicyConfigRegistry.t.sol` | `LexifiPolicyConfig` and the V3 policies: admin rights, fail-closed default, read-time clamps, and migrated configuration matching legacy behaviour |
| `Aqua0Integration.t.sol` | A third-party venue adapter calling `LexifiComplianceAdapter` from `beforeSwap`, with pass and deny paths |
| `LexifiAllowlistChecker.t.sol` | The Permissioned Pools checker on its own: flags, bindings, pause, fail-closed on a reverting policy |
| `PermissionsAdapterIntegration.t.sol` | Uniswap's real `PermissionsAdapterFactory` and `PermissionsAdapter` with the Lexifi checker plugged in, including a fuzzed check that adapter, checker and `previewPermissions` always agree |

**Method note.** Enforcement is `checkAccess().level >= minimumLevel(operation)`, and tests assert
through that comparison, never on the `reason` string alone. The hook discards `reason` whenever
the comparison passes, so a test on `reason` proves nothing; that is how audit finding 3 first
shipped with a passing test.

---

## 14. Known Limitations

| Limitation | Impact | Mitigation |
|------------|--------|------------|
| No third-party audit | Internal review only (§11) | External audit before an issuer relies on the policies |
| Users behind untrusted routers | The hook identifies the caller as the user unless the router is marked trusted, so users of an unvetted router are denied unless the router itself is verified | The owner marks routers trusted with `setTrustedRouter` |
| Denials leave no events | A revert rolls back `ComplianceCheckFailed` and `AuditRecord` | The dashboard's `/audit` page and the SDK's `fetchAuditTrail` reconstruct denials from reverted transactions and mark them as reconstructed |
| ThresholdPolicy gates liquidity on tier alone | Through the hook, a RETAIL address denied a large swap can still add liquidity | Closed on the Permissioned Pools path by `liquidityRequiresSwap` (on by default). Closing it in the policy would change what the policy means |
| The Permissioned Pools path is size-blind and silent | `checkAllowlist` gets no pool id, operation or amount, and is `view` | Pools that need amount rules or the audit trail use `LexifiHook` directly |
| Coinbase Verifications exist only on Base | On any other chain `CoinbaseEASProvider` returns tier 0 for everyone and the stack fails closed | Use `SelfAttestationProvider` off Base; confirmed necessary on Robinhood Chain (2026-09-07) |
| One Safe holds every admin right | The Safe's threshold is 1-of-1, so a single signer controls ownership and pool admin | Raise the Safe to a multi-signer threshold with signers on separate devices |
| Policy contracts are trusted | A malicious policy can admit anyone or brick a pool | `requireApproval` plus the owner's approved-policy list; currently `requireApproval = false` |
| Immutable policies | A logic bug means a new policy and re-pointed pools | V3 keeps configuration in `LexifiPolicyConfig`, so no configuration migration is needed |
| No caching in the hook | Every check makes several external calls | Policies can cache internally |
