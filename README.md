# ETH Fee (ETHF) + ETHOnlyFeeHook

Source, tests and ABI exports for the `lab-eth-fee-hook` launch on Sepolia (chain id 11155111): a
fixed-supply ERC-20 and a Uniswap v4 hook that takes a constant 0.5% fee in native ETH on every swap of
an ETH pool and hands it to that pool's in-range liquidity providers.

This assignment delivers the contracts, their tests and `docs/abi/*.json`. The launch manifest
(`launch.json`) is produced by a separate assignment, and publication, attestation, admission,
deployment through the launch factory and the website are later service steps.

## Contents

| Path | What it is |
| --- | --- |
| `src/ETHF.sol` | The token. 1,000,000,000 ETHF, 18 decimals, minted once to `msg.sender`. No constructor arguments, no owner, no mint. |
| `src/ETHOnlyFeeHook.sol` | The hook. Constructor takes only the PoolManager. No owner, no admin, no fee setter. |
| `src/HookFlags.sol` | The 14 hook permission bits and two helpers to check an address against a declared set. |
| `script/Deploy.s.sol` | Reference deployment (salt mining + deploy). Constants only, no env reads. Tests call `deploy` directly. |
| `test/` | Foundry tests against a real v4-core `PoolManager` (see "Tests"). `test/mocks/MockERC20.sol` is the test token the admission floor imports. |
| `docs/abi/ETHF.json`, `docs/abi/ETHOnlyFeeHook.json` | ABI exports (`forge inspect <Contract> abi --json`). |
| `lib/` | Vendored dependencies as ordinary files (no submodules, see "Dependencies"). |

## Token: ETHF

* Name `ETH Fee`, symbol `ETHF`, 18 decimals, total supply `1_000_000_000e18`, all minted in the
  constructor to the deployer. The launch factory deploys it and therefore holds the whole supply.
* OpenZeppelin `ERC20` v5.4.0 with nothing added: no mint, burn, pause, owner, proxy, `DELEGATECALL`
  or `SELFDESTRUCT`. `transfer` moves exactly the requested amount.

## Hook: ETHOnlyFeeHook

### Deployment parameters

| Parameter | Value |
| --- | --- |
| Base | `v4-periphery` `BaseHook` (`ImmutableState` + `IHooks`), v4-core `PoolManager` interfaces |
| Constructor | `constructor(IPoolManager poolManager)`; on Sepolia `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Permissions | `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta`, nothing else |
| Address flags | low 14 bits must equal `0x00CC` (`0x80 | 0x40 | 0x08 | 0x04`); the constructor reverts `HookAddressNotValid` otherwise |
| Salt | mined with `HookMiner.find(deployer, 0x00CC, creationCode, abi.encode(poolManager))`; `Deploy.mineSalt` does this |
| Fee | constant `50` bps of the swap's ETH amount, rounded up, always in native ETH |
| Launch pool key | `currency0 = 0x0` (native ETH), `currency1 = ETHF`, `fee = 3000`, `tickSpacing = 60`, `hooks = <hook>` |
| Compiler | `solc 0.8.26`, `evm_version = cancun` (transient storage), optimizer on, `bytecode_hash = "none"` |

The hook keys all state by `PoolId`, so any pool may attach it. Pools whose `currency0` is not native
ETH receive zero deltas and pay nothing (tested).

### Fee rules

`fee = ceil(ethAmount * 50 / 10_000)`. In v4, `amountSpecified < 0` is exact input and `zeroForOne` is a
buy (ETH in, ETHF out). Native ETH is the specified currency when `exactInput == zeroForOne`.

| Case | Direction | Where | What happens |
| --- | --- | --- | --- |
| (a) | buy, exact input | `beforeSwap`, positive specified delta | fee comes off the ETH input; the pool swaps `amount - fee` |
| (b) | sell, exact output | `beforeSwap`, positive specified delta | the pool pays `amount + fee`; the seller receives exactly `amount` |
| (c) | buy, exact output | `afterSwap`, positive unspecified delta | fee on the pool's ETH delta; the buyer pays `poolEth + fee` |
| (d) | sell, exact input | `afterSwap`, positive unspecified delta | fee on the pool's ETH delta; the seller receives `poolEth - fee` |

In every case the swapper's ETH change equals the pool's ETH delta minus exactly the fee.

Reverts (bubbled by the PoolManager as `WrappedError(hook, callbackSelector, reason, HookCallFailed)`):

* `PartialFill` from `afterSwap` in (a) and (b) when the pool did not move the whole adjusted amount, i.e.
  the swap stopped at `sqrtPriceLimitX96`. In (c) and (d) partial fills are allowed: the fee is simply
  charged on whatever ETH moved.
* `SwapTooSmall` when nothing would be left for the swapper after the fee: in (a) when `amount - fee == 0`
  (e.g. 1 wei in), in (d) when the pool's ETH output minus the fee is zero (including a zero output).
  (b) and (c) add the fee on top of the swapper's side and cannot trigger it.

### Settlement: claims, not transfers

`afterSwap` calls `poolManager.mint(hook, 0, fee)`, turning the hook's positive ETH delta into ERC-6909
claims on currency id 0. No ETH is transferred during a swap, which is why the first buy into the
factory's ETH-less pool works. The ETH backing the claims sits in the PoolManager.

### Donation: the one way out

`donateFees(PoolKey key)` is permissionless. It unlocks the PoolManager, burns the pool's accrued claims
and calls `donate(key, amount, 0, "")`, so the ETH goes to the pool's in-range LPs as currency0 only.
`feeGrowthGlobal0X128` rises by exactly `amount * 2^128 / liquidity`.

* Reverts `NothingToDonate` when `accrued(poolId) == 0` and `NoLiquidity` while the pool's in-range
  liquidity is zero; the claims wait for a later call.
* `unlockCallback` accepts only the PoolManager and only during an unlock this contract started (a
  transient flag set by `donateFees`); a third party unlocking the manager cannot drive it.
* No path touches LP principal. The hook never holds ETH (no `receive`), never earns claims on any
  other currency, and cannot be paused, upgraded or drained.

Events: `FeeTaken(PoolId indexed poolId, address sender, bool buy, uint256 ethAmount, uint256 fee)` and
`FeesDonated(PoolId indexed poolId, uint256 amount)`. Views: `accrued(poolId)`, `totalCollected(poolId)`,
`totalDonated(poolId)`, `feeOn(ethAmount)`, `FEE_BPS`, `BPS_DENOMINATOR`.

Invariant (tested): the hook's ETH claim balance `poolManager.balanceOf(hook, 0)` equals the sum over
pools of `totalCollected - totalDonated`, which equals the sum of `accrued`.

## Assumptions

* **`sender` in `FeeTaken` is the router.** It is the address that called `PoolManager.swap`
  (`PoolSwapTest` at `0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe` for the website), not the end user.
* **`hookData` is ignored and unauthenticated.** The hook credits nobody per swapper, so no identity is
  read from it. Any value, including none, is accepted.
* **Pool fee tier is static.** The fee is taken through return deltas, not a dynamic LP fee, so the
  launch key uses a plain `fee = 3000`.
* **Only native ETH pools are charged.** Wrapped-ETH pools (`currency0` = WETH) are ERC-20 pools to
  the hook and pay nothing.
* **The factory's pool initialisation and one-sided seed are never blocked.** The hook has no
  initialize or liquidity callbacks. `test_launchRehearsal` opens the pool, seeds ETHF only below the
  opening price, buys into the ETH-less pool, then sells.
* **Rounding.** The fee rounds up, so any non-zero ETH amount pays at least 1 wei. Donated ETH reaches
  LPs through v4's fee growth accounting and is subject to its usual downward rounding on collection.
* **Deployment sender.** `Deploy.run` mines a salt for the CREATE2 proxy `forge script` uses. The
  factory deploys with its own address, so it must mine its own salt for the same creation code; the
  flags requirement is identical. Nothing in this repository authorises a transaction or holds keys.

## Operational responsibilities

* **Calling `donateFees`.** Nobody is obliged to. Fees accumulate as claims until someone (the website's
  donate button, a keeper, an LP) calls it. If in-range liquidity is zero the call reverts and the
  claims keep waiting; nothing is lost.
* **Address mining.** Whoever deploys must place the hook on an address whose low 14 bits are `0x00CC`.
  The constructor enforces it, and the admission floor re-checks `getHookPermissions` against the
  manifest and the address.
* **No admin.** There is no owner, pause, upgrade or fee change. Changing anything means a new hook and a
  new pool.
* **Security review.** Tests are not an audit. The hook enables two return-delta permissions (both
  HIGH/CRITICAL in the v4 risk matrix); the independent review step must confirm the delta accounting
  in `_beforeSwap`/`_afterSwap` and the `donateFees` unlock path before deployment.

## Tests

```
forge build
forge test
forge fmt --check
```

`test/ETHOnlyFeeHook.t.sol` runs against a real `PoolManager` from v4-core and covers: permission set
and address flags, constructor rejection of an unflagged address, fee rounding (unit + fuzz), the launch
rehearsal, the four fee paths (unit + fuzz over all four), `PartialFill` for (a) and (b) and its absence
for (c), `SwapTooSmall` on both edges, insufficient ETH, ignored `hookData`, ERC-20 pools paying
nothing, per-pool accounting across two ETH pools, `donateFees` fee-growth delta and LP collection,
`NoLiquidity`, `NothingToDonate`, repeat donations, callback and `unlockCallback` access control, a
foreign unlock, and the absence of `receive` or admin selectors. `test/ETHOnlyFeeHook.invariant.t.sol`
drives two ETH pools and one ERC-20 pool through all swap modes, donations and liquidity changes and
checks the claims invariant. `test/ETHF.t.sol` and `test/Deploy.t.sol` cover the token and the script.

Tests read no environment variables and do not depend on the calling address, so they run in any order
and in parallel. The admission floor (`Hook.protected.t.sol`, `Token.protected.t.sol`) imports
`src/HookFlags.sol` and `test/mocks/MockERC20.sol` from this layout and was rehearsed locally against
the compiled creation code with `IMD_HOOK_FLAGS=204` and the Sepolia PoolManager address.

## Dependencies

Everything under `lib/` is committed as plain files so an offline build works. No git submodules.

| Library | Source | Files vendored |
| --- | --- | --- |
| v4-core | `Uniswap/v4-core` @ `46c6834` | `src/**`, `test/utils/CurrencySettler.sol`, licenses |
| v4-periphery | `Uniswap/v4-periphery` @ `3779387` (last commit before `BaseHook` moved to the hooks repo) | `src/utils/BaseHook.sol`, `src/utils/HookMiner.sol`, `src/base/ImmutableState.sol`, `src/interfaces/IImmutableState.sol`, LICENSE |
| solmate | `transmissions11/solmate` @ `4b47a19` (v4-core's pin) | `src/auth/Owned.sol` (needed by `ProtocolFees`), LICENSE |
| openzeppelin-contracts | v5.4.0 | `ERC20`, `IERC20`, `IERC20Metadata`, `Context`, `draft-IERC6093`, LICENSE |
| forge-std | `foundry-rs/forge-std` @ `3e2295d` | `src/**`, licenses |

Remappings are in `remappings.txt`. `foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`,
`bytecode_hash = "none"`, and keeps `ffi` and filesystem permissions off.
