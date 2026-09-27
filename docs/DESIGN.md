# ETH Fee — implemented design

## Overview

A compact public interface for Sepolia traders and liquidity providers. A warm paper background, dark green-gray text and one burnt-orange primary action distinguish pool information from transaction controls. The composition is deliberately quiet: a brief explanation, three aligned ETH totals, donation and swap controls, then recent events and expandable contract details.

The one-page implementation is `web/src/main.tsx`; the complete style system is `web/src/style.css`. The scope restriction places this document under `docs/` instead of the requested but forbidden root path.

## Colors

The canonical format is hex. Primitive values feed semantic roles in `style.css:11`; components consume semantic tokens.

| Semantic token | Value | Use |
| --- | --- | --- |
| `--color-bg` | `#f6f5ef` | Page and input panels |
| `--color-surface` | `#ffffff` | Swap card, unaccented metric cards |
| `--color-inset` | `#eeeee5` | Segments, inactive controls, empty events |
| `--color-tint` | `#e3e4d8` | Accrued-fee metric and transaction status |
| `--color-text` | `#253127` | Main text, ETH symbol and token mark |
| `--color-muted` | `#596253` | Supporting text and captions |
| `--color-border` | `#d4d7cb` | Structural dividers |
| `--color-control-border` | `#81877c` | Control outlines |
| `--color-accent` / `--color-accent-hover` | `#bd4024` / `#a7351d` | Primary swap/connect action |
| `--color-on-accent` | `#ffffff` | Primary button text |
| `--color-focus` | `#bd4024` | 3px focus outline with 4px offset |
| `--color-error` / `--color-error-bg` | `#922d21` / `#fff0ea` | Recoverable error messages |
| `--color-live` | `#42744f` | Live-read dot, accompanied by status text |

Measured rendered pairs are recorded in `evidence/browser-results.json`: secondary text on the tinted card is 4.96:1, on paper 5.83:1, and on white 6.37:1. White text on the primary button is 5.35:1. There is one supported light theme; no unused dark theme or ramps are implied.

## Typography

System sans stack: `Avenir Next`, `Segoe UI`, Arial, sans-serif. Small metadata and full addresses use `SFMono-Regular`, Consolas, `Liberation Mono`, monospace. No font files or external requests are required; the actual system fallback depends on the device. Regular, medium, semibold and bold weights are requested, without claiming each operating system provides separate faces.

The root is 16px / 1.5, with antialiasing and tabular numerals. Hero text is `clamp(42px, 4.7vw, 62px)`, line-height 1.04 and tracking −0.055em; at the narrowest breakpoint it is 40px. Donation headings are 38px / 1.14 (34px or 32px at narrower widths). Section headings are 21–24px; metrics are 24–36px, 32px when stacked. Body descriptions are 15–16px with 1.65–1.7 line-height; controls 14px, captions 13px, compact metadata 10–12px. The small uppercase eyebrows are secondary orientation, never the sole label for an action.

Inputs are 30px, 26px at the narrowest width. Selects remain 16px. Quote output is 30px, reduced to 18px at 368px and below so a realistic 4,938.170826 ETHF quote stays readable in its column. Headings balance lines; prose uses pretty wrapping; addresses can break anywhere. Exact metric amounts are retained in titles, and full addresses are available in the contract disclosure. No full-interface selection suppression is used.

## Layout

`.shell` is at most 1120px wide with 40px desktop side gutters. Metrics use three equal columns. `.workspace` places donation and swap in equal columns, separated by 76px; the swap is a bounded white card. Most control spacing is 12–20px, group spacing 24–42px, and major section spacing 30–58px. Body text in the donation panel is capped at 38 characters.

Breakpoints are 60rem, 46rem and 23rem. At 60rem, gutters become 24px and columns have 32px gaps. At 46rem, gutters become 16px, metrics and action panels stack in DOM order, the decorative fee circle disappears, and contract details stack. At 23rem, the header wraps and the swap card padding becomes 16px. All actions remain in normal document flow. The narrowest 320px viewport, 390px, 800px and 1440px were checked for overflow. Browser-native zoom was not verified; the root-font enlargement check is separate and does not prove that pixel-sized text doubled.

## Elevation & Depth

Structural borders provide most separation. The swap card alone has restrained shadows: `0 2px 2px #25312703` and `0 12px 32px #25312705`. The accrued-fee card uses a tonal background. No dialogs, floating overlays or sticky action bars exist.

## Shapes

Metric group: 16px outer radius, clipped continuous borders. Swap card: 22px radius, 20–26px padding on most widths. Input panels: 10px radius. Buttons, segments, errors and empty states: 8px radius. Small badges: 4–6px radius. Token icons and the decorative fee diagram use circles. ETH marks are simple inline SVGs; the favicon is a local SVG using the same colors.

## Components

All product patterns live in `main.tsx`; the only extracted visual helpers are `Mark` and `Arrow`.

| Pattern | Classes / behavior |
| --- | --- |
| Wallet header | `.header`, `.wallet-group`, `.badge`; address or connect control; a separate visible switch control on the wrong chain |
| ETH metrics | `.metrics`, `.metric`, `.accrued`; meaningful labels, units, unrounded titles, live/loading/error state above |
| Donation | `.donation-panel`, `.donation-flow`, `.donate`; fee source and gas explained, eligibility reason adjacent to disabled action |
| Swap | `.swap-panel`, `.segmented`, `.amount-box`, `.tolerance`, `.quote-details`; native direction buttons with `aria-pressed`, bound labels, exact-input controls and separate quote/approval/write steps |
| Buttons | `.button`, `.small`, `.primary`, `.text-button`; hover, focus, active, pending and disabled states; primary orange reserved for the swap/connect action |
| Notices | `.notice.error`, `.notice.network`, `.feedback`, `.transaction`; errors use alerts, routine status uses a stable polite region, transaction hashes link to explorer |
| Disclosures | Native `details` / `summary` for price protection and contract details; keyboard operation supplied by the browser |
| Events | `.event-list` / `.empty-state`; latest bounded event window is distinguished from lifetime totals |

Minimum main control height is 44–48px; segmented controls are 40px high. Focus uses a visible 3px outline. Press scaling to 0.96 and 120ms transitions only run under `prefers-reduced-motion: no-preference`; reduced motion has no transforms/transitions. Error or receipt changes scroll their feedback into view without smooth animation. The first keyboard target is a skip link. Field validation focuses the invalid input. Native disabled controls enforce unavailable transaction prerequisites.

## Do's and Don'ts

- Reuse the shell, semantic colors and native controls for additional content. Keep each transaction's reason and outcome close to its control.
- Use one orange primary action; secondary donation and quote controls remain outlined.
- Preserve token units, tabular figures and complete address access. Never replace an RPC error with invented zero totals.
- Keep exact deployment data in the generated manifest and use the shared loader. Do not add an address map to a component.
- Extend the existing sections or use hash navigation if another view is necessary; static hosts cannot assume server rewrites.
- Keep new motion optional and respect reduced motion. Do not add animation or themes to fill a checklist.

Design principles were applied from the pinned Better Interface reference (Jakub Krehel, MIT, commit `267330e1adfc66a718fb65fa6918c1f06d0a689e`). Documentation method follows the pinned Impeccable reference (Paul Bakaus, Apache-2.0, commit `9d715cc4f5564a990ca8345abfdd5df6dc9b41c8`). This document describes the implementation; it does not reproduce or relicense either guide.
