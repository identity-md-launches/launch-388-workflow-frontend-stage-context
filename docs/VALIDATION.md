# Frontend validation — ETH Fee

Worker report, 2026-09-27. These are recorded local checks, not an independent certification or a publication result.

## Scope and consequential choices

One Vite / React / TypeScript page, no backend. Frontend source/configuration/lockfile/tests are in `web/`, the complete export in `dist/`, and evidence in `docs/evidence/`. Contract source, root configuration and `lib/` are unchanged. The root-design-document sentence conflicts with the overriding allowed paths; the final document is `docs/DESIGN.md`. The explicit ignore-file budget is one file, `web/.gitignore`.

The specific assignment and workflow require PoolSwapTest. The generic Universal Router / Permit2 example was not substituted. PoolSwapTest comes from the approved workflow; quote, price and manager addresses come from the unchanged network table. Direct exact-amount token approval is required by PoolSwapTest's preserved `CurrencySettler` implementation. The interface states that this router provides a price limit but no minimum-output or deadline enforcement. It does not promise Universal Router protections.

Implemented primary actions: quote either exact-input direction, approve ETHF for the requested sell amount, swap, and donate all accrued fees. Contract callbacks, ERC-6909 claim internals and generic ERC-20 transfers are not visitor actions on this scoped page.

## Commands and outcomes

Commands ran from `web/` unless stated otherwise:

| Check | Result |
| --- | --- |
| `npm install --no-audit --no-fund --cache /tmp/ethfee-npm-cache` | Installed normal frontend dependencies; package-lock created. No vendored registry or dependency archives delivered. |
| `npm run build` | Passed after final source changes; includes `tsc --noEmit`, Vite build and manifest generation. |
| `npm run typecheck` | Passed separately. |
| `npm test` | 5 passing tests: fee ceiling/dust, input precision, directional price limits, signed delta decoding, recovery messages. |
| `npm run test:browser` | 27 passing checks against the actual production export served under `/preview/`, Chromium 154.0.8037.0. |
| `npm run verify` | Passed: 10 assets, 532,472 asset bytes excluding manifest, exact SHA-256 inventory, both pinned canonical ABI hashes and handoff/network match. |
| `node scripts/live-check.mjs` | Read-only RPC chain/code checks passed for all three public endpoints; pool state and buy quote succeeded. Sell quote reverted; see below. |
| Supplied browser tool | Inspected the final export with real configured RPCs at 1440×1050 and 320×1000, including a live read-only buy quote, screenshots, console and local resources. |

The final production JS is approximately 480 kB uncompressed (150 kB gzip); no source maps, external fonts or runtime CDN assets are shipped. There are five ABI JSON files, two JS chunks, one CSS file, index.html and a favicon. The manifest itself is excluded from its inventory. Source and required runtime assets remain complete.

## Interaction evidence

`evidence/browser-results.json` records all checks, measured rendered contrast, browser version, screenshot paths, zero uncaught JavaScript errors and zero failed static resource responses. `web/tests/browser.mjs` is rerunnable and uses the same production assets. Wallet submissions are captured by a fake provider; public RPC reads and receipts are mocked only in this suite.

Validated flows include:

- Disconnected live-read layout, disabled transaction controls, and missing-wallet recovery.
- Wrong-chain gating; an unknown-chain 4902 response; exact `wallet_addEthereumChain` payload; second switch attempt.
- Invalid amount focus/ARIA behavior; native buy quote and rounded fee preview.
- Wallet rejection, preflight revert preventing a write, pending write gating and receipt confirmation.
- Buy calldata uses the workflow router, negative exact input, correct native value, directional price limit and empty hookData; no approval.
- Donation simulation/write, zero personal ETH value, receipt and refreshed zero accrued state.
- Sell's separate exact-amount approval to PoolSwapTest, new quote, zero native value and opposite price-limit direction.
- Quote invalidation after tolerance/account changes and 45-second expiry.
- No accrued fees, no in-range liquidity, missing contract code, retry recovery, RPC outage and unavailable event logs.
- Tampered runtime ABI rejection.

The 5,000-block event window is explicit and separate from lifetime totals. Receipt replacement/drop, real wallet extension UX, hardware wallets and live signing are not covered by mock receipts.

## Live observations, separately recorded

`evidence/live-rpc.json` is a real read-only check through viem. All three configured URLs returned chain ID 11155111 and nonempty code for ETHF, ETHOnlyFeeHook, PoolSwapTest, PoolManager, V4Quoter and StateView. The hook and router reported the configured manager; ETHF returned 18 decimals and the hook returned 50 basis points.

At the sampled state, accrued, collected and donated amounts were all zero; current in-range liquidity was zero. A read-only quote of 0.0001 ETH succeeded with 4,938.170826239599674012 ETHF output. A quote selling 1 ETHF reverted with signature `0x6190b2b0`; this is **not** recorded as a successful live sell. A zero-liquidity current tick can still permit a buy to cross into the one-sided seed; the app allows the quoter and subsequent swap simulation to decide instead of disabling all swaps solely on the current liquidity value.

The supplied browser then loaded actual state at block 11,791,824 and displayed the same buy estimate. `live-desktop.png` and `live-mobile.png` contain these live reads with no wallet connected. Both have no horizontal overflow. `live-console.txt` reports zero errors/warnings, and `live-resources.txt` records all local assets/config/ABI requests as HTTP 200. These local URLs are preview evidence, not published site addresses.

An earlier Python HTTP probe received 403 from the endpoints. The actual viem transport and browser checks subsequently succeeded; the earlier transport failure is not treated as evidence that the app's RPC reads fail.

No real transaction was signed or broadcast. Real approvals, buys, sells and donations, receipt finality and actual wallet chain installation remain untested. No deployment, hosting, IPFS pinning, naming or control-plane publication checks were performed.

## Better Interface coverage

Read and applied the pinned workflow and core principles of all six domains, followed by the design-document method. Source review was combined with browser interaction and visual inspection; it was not substituted for them.

| Domain | Coverage and evidence | Limits |
| --- | --- | --- |
| Accessibility | Checked native landmarks/buttons/details, bound input labels, invalid-field focus, skip link, status/alert regions, keyboard amount → tolerance → quote flow, reduced-motion behavior. Axe WCAG A/AA scans found zero violations at 1440, 800, 390 and 320px. Focus screenshot was visually inspected. | No screen-reader session, physical mobile device, forced-colors session or exhaustive keyboard traversal of every explorer link. An automated scan is not full accessibility certification. |
| Layout | Checked both column layouts and stacked mobile layouts, 320px reflow, normal-flow actions, long addresses, desktop/mobile screenshots, and no horizontal overflow at all four tested widths. | Native browser 200% zoom was not verified. The separate root-font-size check did not prove every pixel-sized label enlarged. No RTL or translated UI is implemented. |
| Writing | Checked action labels against actual handlers, fee source, personal-gas distinction, approvals, recovery copy, precise lifetime versus recent history and router protection limits. | Raw unknown RPC/contract errors can retain a technical signature; live sell revert is recorded, not reinterpreted as success. |
| Typography | Checked descending hierarchy, system font stacks, numeric stability, control text, full addresses and the actual live 4,938.170826 quote at 320px after correction. | Platform font-face differences and non-Chromium rendering are unverified. |
| Colors | Checked semantic tokens and real foreground/background pairs; fixed tinted-card contrast; recorded ratios in JSON. Final secondary/tinted pair 4.96:1; primary button pair 5.35:1. | One light theme. No gradients/images behind text or secondary theme requiring inspection. |
| UI | Checked selected, hover, focus, active, disabled, loading, error, empty and pending/confirmed patterns; native disclosures; restrained surfaces; reduced motion disables press transitions. | No dialogs or complex motion exist. No 10%-speed animation-panel session was performed. |

## Findings, corrections and rechecks

| Severity / domain | Source location | Reproduced finding and fix | Recheck |
| --- | --- | --- | --- |
| High / colors, accessibility | `web/src/style.css:13` | Muted `#656d61` text on the tinted accrued card measured only 4.17:1. Darkened the shared muted primitive to `#596253`. | Rendered ratio 4.96:1; all four viewport axe scans pass. |
| Medium / writing, layout | `web/src/main.tsx:139` | Hiding the donation heading's line break joined “feesback” at narrow width. Added the missing text space. | Final mocked and live 320px screenshots show correct word separation. |
| Medium / typography | `web/src/style.css:100` | Real quote 4,938.170826 split its final digit onto another line at 320px. Narrow quote output now uses 18px instead of 26px. | Final live mobile screenshot displays the entire quote on one line. |
| Medium / accessibility, UI | `web/src/main.tsx:42` | Error/transaction feedback can lie below the tall mobile action area. New errors and transaction updates now scroll their feedback into view without motion. | Rejection and receipt interactions pass on the final export; source confirms nearest-block scrolling. |
| Medium / writing | `web/src/main.tsx:161`, `web/src/chain.ts:73` | PoolSwapTest does not offer min-output/deadline guarantees. Added always-visible protection wording, directional price limits, fresh-quote gating and mandatory simulation. | Mock buy/sell calldata and expiry checks pass; runtime explanation is visible beside the action. |
| Low / UI resources | `web/index.html:8`, `web/public/favicon.svg` | Browser requested missing `/favicon.ico`, producing a console 404. Added a relative local favicon. | Final live browser console has zero errors; favicon returns HTTP 200 and is inventoried. |

Test-harness fixes were separate from product findings: corrected a signed-bigint test expression and normalized decoded checksum address casing. Browser contexts are closed between scenarios after an earlier simultaneous-page run reached the worker's process limit. The completed final run passed all 27 checks. No abandoned failed-run report is labeled as the final pass.

## Evidence index and remaining limits

- Mock screenshots: `evidence/desktop.png`, `mobile-390.png`, `mobile-320.png`, `focus.png`.
- Real RPC/browser evidence: `evidence/live-rpc.json`, `live-desktop.png`, `live-mobile.png`, `live-console.txt`, `live-resources.txt`.
- Reproducible tests: `web/tests/math.test.ts`, `browser.mjs`, `harness.mjs`.
- Design extraction: `docs/DESIGN.md`; install/build/configuration details: `web/README.md`.

The bounded implementation, export and worker validation are complete. The requested Git commit is blocked by the workspace's read-only `.git` mount: `git add -- web dist docs` failed with `Unable to create .git/index.lock: Read-only file system`. No commit was created or claimed. All deliverable files remain in the allowed working-tree paths for the contributor system to collect. The existing Git metadata was not bypassed or replaced.

The source's PoolSwapTest limitation is visible in the product, not hidden by a fictitious minimum-output promise. Pending transaction state is session-only; event history is bounded; no WalletConnect project ID was supplied. Real signed transactions and publication checks remain untested as stated above.

`evidence/submission-audit.json` records the final path/packaging audit. The export including its manifest is 536,511 bytes. The whole repository candidate (existing tracked files plus new deliverables), existing Git objects and a 256 KiB metadata allowance total less than 4 MiB, comfortably below the 8 MiB submission ceiling. No dependencies, caches, archives, symlinks or submodules are included. The existing tracked files have no diff, so protected contract/build files and the original implementation ABI exports are preserved. A literal Git bundle could not be generated for the new files because staging/committing is unavailable; the recorded size is a conservative file/object bound, not a claimed bundle measurement.
