# Attest a wallet, and show the pool flip from denied to allowed

`index.html` is a single page with no build step and no dependencies. It reads the live policy over
JSON-RPC and sends `attest()` through an injected wallet, so the provider's owner key never leaves
that wallet.

```bash
cd guide/attest && python3 -m http.server 8777
```

Then open <http://localhost:8777> in a browser with Rabby or MetaMask. A wallet extension will not
inject into a `file://` page, which is why this is served over HTTP.

**The demo, in three clicks:**

1. **Check** a wallet at 1 ETH — it reads `DENIED`, level 0 against the pool's required level 2.
2. **Attest** it at tier 2, signed by the provider's owner.
3. **Check** again — the same wallet, same pool, now `ALLOWED`.

Checking the same wallet at 0.00001 ETH shows the other half of the rule: trades below the pool's
no-KYC limit pass without any attestation.

Live on Robinhood Chain (4663): provider `0xC9F31Cb33BEC349691E11A6C62B1428C3c7C201B`, policy
`0xBaa8ba3000Ee1087B0B52937078F4D4f146dF28C`, pool
`0x17fbcda00d5252905f0a63d2527601990cd5759939c22eb682b220a9c1505f42`.
