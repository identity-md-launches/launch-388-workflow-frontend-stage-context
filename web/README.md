# ETH Fee frontend

One static page for the deployed ETHF / native-ETH pool on Sepolia: accrued, collected and donated ETH; permissionless `donateFees`; exact-input buys and sells through the workflow's PoolSwapTest; quotes and fee previews; explicit token approval; wallet and transaction status. No backend, credentials, analytics, remote fonts, WalletConnect service or contract changes.

## Install, build and preview

Tested with Node 24.21.0 and npm 11.19.0. Run from `web/`:

```sh
npm ci
npm run build
npm run preview
```

Open the URL printed by Vite. The export is repository-root `dist/`, with `base: './'`, one page and relative assets. Host the entire directory; server rewrites are unnecessary. `file://` is not supported because deployment/ABI JSON is fetched. Use HTTP(S), including a gateway subpath. Re-run `npm run build` after source changes, then reload the preview. The preview uses the built files, not hot reloading.

The build typechecks, bundles the app, exports ABIs, and **last** creates `dist/imd-deployment.json`. Do not edit an exported file by hand: rebuild so its inventory stays correct. The publisher hosts the committed export without rebuilding it.

## Deployment configuration and provenance

The browser loads **only `dist/imd-deployment.json`** for deployment/network configuration, then its referenced ABI JSON. `src/config.ts` is a loader and validator, not another address map.

Build inputs are kept together under `web/config/`:

- `deployment.json`: exact supplied deployment handoff, deployed commit `cf8a02ce67486ab661fb9438fa83608d0b1a540d`.
- `network.json`: exact supplied network and `walletAddChain` object. The network block is copied unchanged into the export.
- `workflow.json`: the approved workflow's PoolSwapTest address, which is absent from the network table.

`scripts/export.mjs` retrieves each implementation ABI with `git show <sourceCommit>:docs/abi/<Contract>.json`, verifies canonical Keccak-256 against the handoff, checks the delivered ABI copy, and exports the original JSON-array bytes. Canonicalization recursively sorts object keys, preserves array order and uses compact JSON. Keep the deployed commit available in Git history for rebuilding. The build compares the original pinned inputs when present, but does not require `.imd/reads/` after submission.

The handoff's exact two-contract set is retained. Supplemental protocol ABIs are separately inventoried assets. Their signatures come from the preserved PoolSwapTest implementation and the official Uniswap [IV4Quoter](https://raw.githubusercontent.com/Uniswap/v4-periphery/main/src/interfaces/IV4Quoter.sol) and [IStateView](https://raw.githubusercontent.com/Uniswap/v4-periphery/main/src/interfaces/IStateView.sol) interfaces. The pool key comes from the handoff; the native paired currency is zero. The app computes the pool ID with ABI encoding and Keccak, never from a guessed identifier.

The manifest also contains the pool, token, deployment block, workflow router, add-chain payload and protocol ABI paths. Every other exported file is inventoried with SHA-256, including index.html, favicon, JS/CSS and all five ABI files. The manifest excludes itself. Verification rejects more than 128 assets, a file over 8 MiB, unsafe export symlinks, or stale hashes.

## Router choice and transaction behavior

The assignment and approved workflow explicitly require **PoolSwapTest**. This takes precedence over the background Universal Router example. StateView, V4Quoter and PoolManager come from the supplied network block. No alternate Uniswap addresses are remembered or looked up. ETHF approvals target PoolSwapTest directly, as its settlement implementation calls ERC-20 `transferFrom`; Permit2 and Universal Router approvals would not enable this route. The unchanged network table still includes those addresses for transparency.

- Exact-input buys: negative `amountSpecified`, `zeroForOne=true`, transaction value exactly the input, no approval. Fee is `ceil(input × 50 / 10000)` ETH.
- Exact-input sells: `zeroForOne=false`, no native value, separately approve only the entered ETHF amount to PoolSwapTest, confirm the receipt, then get a new quote. The ETH fee preview is inferred from the net quote and can differ by one wei.
- Quotes call V4Quoter through `simulateContract` / `eth_call`. They never send transactions. Prices come from StateView.
- PoolSwapTest has **no minimum-output or deadline parameter**. The interface exposes a pool-price tolerance and forwards `sqrtPriceLimitX96`, computed with integer square-root math. It forwards empty `hookData`; the deployed hook ignores it. FeeTaken's sender is a router, not the trader, and hookData does not authenticate anyone.
- Every write is simulated before signing. The simulated swap delta is decoded and checked against the quote tolerance. This is a preflight check, not an onchain minimum-output guarantee. Buys must fill completely or the hook reverts. Sells may fill partially; unspent input stays in the wallet. Quotes expire in the UI after 45 seconds; already submitted transactions have no onchain expiry.
- Donation submits `donateFees(poolKey)` with no personal ETH value. The caller pays gas. Zero accrued fees or zero in-range liquidity disables the action.

Transactions require a connected wallet on the correct chain, verified contract code/manager bindings, matching decimals and fee, and successful recent reads. Account and chain are rechecked before writing. Missing-chain switch errors offer `wallet_addEthereumChain` using the exact supplied payload, then switch again. Errors, rejection, pending hashes, receipt status and explorer links are visible. Pending receipts disable further writes. A replaced/dropped transaction may remain pending until reload; keep its explorer link and check it before trying again. Pending state is not persisted across reloads.

Public reads work before connection and refresh every 30 seconds. Connected balances and allowances are read at the same block as pool state. Failed or stale reads disable actions. RPCs use the configured fallback order; a connected provider on the correct chain is a final read fallback. The latest five FeesDonated events in up to 5,000 blocks are shown; the three totals are lifetime contract views, not sums of this bounded event window. Event-query failures do not invent an empty history or overwrite totals.

Only the browser's injected EIP-1193 wallet is supported. No WalletConnect project ID was supplied; adding that connector is optional future work and requires its own public configuration.

## Validation

```sh
npm run typecheck
npm test
npm run build
npm run verify
npm run test:browser
node scripts/live-check.mjs
```

For browser tests outside this worker, install Chromium with `npx playwright install chromium`, or set `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH`. The worker uses its supplied Chromium. `test:browser` starts and closes a bounded local HTTP server, serves the **built export under `/preview/`**, injects a fake wallet and mocks RPC responses. No signing keys or live writes are used. It records tests, contrast measurements and screenshots under `docs/evidence/`. The read-only live check records RPC chain/code, pool state and simulated quotes separately; its report distinguishes success from unavailable behavior.

See [validation and limitations](../docs/VALIDATION.md), [implemented design](../docs/DESIGN.md), and [browser results](../docs/evidence/browser-results.json). Mock screenshots contain test data and are explicitly distinguished from `live-*.png` screenshots.

## Scope and size

Source, lockfile, package/build configuration and tests are under `web/`; the complete static export is under `dist/`; documentation/evidence is under `docs/`. Deployed Solidity, ABIs under `docs/abi/`, root build files and dependencies under `lib/` are unchanged.

**Ignore-file path budget: exactly `web/.gitignore` (one explicitly allowed file).** Its patterns exclude dependency and cache directories at every nesting level within the frontend. No other ignore file is edited. Dependencies, caches, tarballs, source maps and browser binaries are not submitted. The source plus export and evidence are far below the 8 MiB bundle limit; final measured totals are recorded in the validation report.

The root `DESIGN.md` acceptance sentence conflicts with the overriding write scope. Its complete content is delivered at `docs/DESIGN.md`; no root file is created. Publication, IPFS pins, names, CIDs and contract redeployment are outside this worker task.
