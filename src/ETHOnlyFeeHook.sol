// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

/// @title ETHOnlyFeeHook
/// @notice Takes a constant 0.5% hook fee, always in native ETH and always on the ETH side of a swap, and
/// forwards everything it collects to the pool's in-range liquidity providers.
///
/// @dev Design summary (see README for the full contract):
///  - Applies to any pool whose `currency0` is native ETH. Pools whose currency0 is anything else get zero
///    deltas from both callbacks and pay nothing. State is keyed by `PoolId`, so any pool may attach the hook.
///  - The fee is `ceil(ethAmount * 50 / 10_000)`.
///    (a) buy, exact input  (zeroForOne, amountSpecified < 0): the fee is taken from the ETH input in
///        `beforeSwap`; the pool swaps the remainder.
///    (b) sell, exact output (!zeroForOne, amountSpecified > 0): the pool is asked for `amountSpecified + fee`
///        ETH in `beforeSwap`; the seller receives exactly `amountSpecified`.
///    (c) buy, exact output and (d) sell, exact input: ETH is the unspecified currency, so the fee is charged
///        on the pool's ETH delta from `afterSwap` (the buyer pays more, the seller receives less).
///    In (a) and (b) `afterSwap` reverts `PartialFill` if the pool did not move the whole adjusted amount
///    (a price limit was hit). In (a) and (d) a swap that would leave the swapper nothing after the fee
///    reverts `SwapTooSmall`.
///  - Fees never move ETH during a swap. `afterSwap` mints the fee to this contract as ERC-6909 claims on
///    currency id 0, which settles the hook's positive delta. That is why the very first buy into a pool that
///    holds no ETH yet works.
///  - The only way out is `donateFees`: anyone may call it, it burns the pool's accrued claims and donates
///    the ETH to that pool's in-range LPs as currency0 only. It reverts `NoLiquidity` while in-range
///    liquidity is zero; the claims simply wait. No path touches LP principal.
///  - No owner, no admin, no fee setter. The only constructor argument is the PoolManager.
///  - `sender` in `FeeTaken` is the address that called `PoolManager.swap` (normally a router), not the
///    end user. `hookData` is ignored.
contract ETHOnlyFeeHook is BaseHook, IUnlockCallback {
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Fee rate in basis points (0.5%).
    uint256 public constant FEE_BPS = 50;
    /// @notice Basis point denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @dev Transient slot set to 1 for the duration of a `donateFees` call, so that `unlockCallback` only
    /// accepts the PoolManager during an unlock this contract started.
    /// Equals `keccak256("ETHOnlyFeeHook.donating")`.
    bytes32 private constant DONATING_SLOT = 0x6afdb718bd4ddf85de79406f1495dba9f3fb139085ed02fc41cde6cc6f61d2c5;

    /// @notice ETH fee claims held for a pool that have not been donated yet.
    mapping(PoolId => uint256) public accrued;
    /// @notice Lifetime ETH fees taken on a pool.
    mapping(PoolId => uint256) public totalCollected;
    /// @notice Lifetime ETH donated to a pool's LPs.
    mapping(PoolId => uint256) public totalDonated;

    /// @notice Emitted for every fee taken.
    /// @param poolId The pool the swap happened in.
    /// @param sender The caller of `PoolManager.swap` (a router, not the end user).
    /// @param buy True when the swap was zeroForOne (ETH in, token out).
    /// @param ethAmount The ETH amount the fee was computed on.
    /// @param fee The ETH fee taken.
    event FeeTaken(PoolId indexed poolId, address sender, bool buy, uint256 ethAmount, uint256 fee);
    /// @notice Emitted when accrued fees are donated to a pool's in-range LPs.
    event FeesDonated(PoolId indexed poolId, uint256 amount);

    /// @notice The pool did not fill the whole adjusted specified amount (a price limit was hit).
    error PartialFill();
    /// @notice The swap is too small to leave anything for the swapper after the fee.
    error SwapTooSmall();
    /// @notice The pool has no in-range liquidity to receive a donation.
    error NoLiquidity();
    /// @notice The pool has no accrued fees to donate.
    error NothingToDonate();
    /// @notice `unlockCallback` was reached outside a `donateFees` call.
    error NotDonating();

    constructor(IPoolManager poolManager) BaseHook(poolManager) {}

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------------------------------
    // Fee math
    // ---------------------------------------------------------------------------------------------

    /// @notice The fee charged on `ethAmount`, rounded up. Zero only when `ethAmount` is zero.
    function feeOn(uint256 ethAmount) public pure returns (uint256) {
        return (ethAmount * FEE_BPS + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
    }

    /// @dev True when native ETH is the specified currency of the swap, i.e. cases (a) and (b).
    function _ethIsSpecified(SwapParams calldata params) private pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    function _abs(int256 x) private pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    // ---------------------------------------------------------------------------------------------
    // Swap callbacks
    // ---------------------------------------------------------------------------------------------

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!key.currency0.isAddressZero() || !_ethIsSpecified(params)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 eth = _abs(params.amountSpecified);
        uint256 fee = feeOn(eth);
        // (a) exact-input buy: the pool must still have something to swap once the fee is removed.
        // (b) exact-output sell: the fee is added on top of what the seller receives, so nothing to check.
        if (params.amountSpecified < 0 && eth - fee == 0) revert SwapTooSmall();

        // A positive specified delta credits the hook with `fee` of the specified currency (ETH) and moves the
        // pool's swap amount by the same quantity: the pool swaps `eth - fee` on a buy, or pays out
        // `eth + fee` on a sell. The credit is settled as claims in `_afterSwap`.
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        if (!key.currency0.isAddressZero()) return (BaseHook.afterSwap.selector, 0);

        uint256 eth;
        uint256 fee;
        int128 unspecifiedDelta = 0;
        uint256 poolEth = _abs(delta.amount0());

        if (_ethIsSpecified(params)) {
            // (a) and (b): the fee was already returned from beforeSwap; verify the pool filled the whole
            // adjusted amount. Exact input: pool moved `eth - fee`. Exact output: pool paid `eth + fee`.
            eth = _abs(params.amountSpecified);
            fee = feeOn(eth);
            uint256 expected = params.amountSpecified < 0 ? eth - fee : eth + fee;
            if (poolEth != expected) revert PartialFill();
        } else {
            // (c) exact-output buy: the buyer pays the pool's ETH plus the fee.
            // (d) exact-input sell: the seller receives the pool's ETH minus the fee.
            eth = poolEth;
            fee = feeOn(eth);
            if (!params.zeroForOne && eth - fee == 0) revert SwapTooSmall();
            unspecifiedDelta = fee.toInt128();
        }

        if (fee > 0) {
            PoolId poolId = key.toId();
            // Convert the hook's positive ETH delta into ERC-6909 claims. No ETH leaves the PoolManager, so
            // the first buy into a pool holding no ETH settles cleanly.
            poolManager.mint(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), fee);
            accrued[poolId] += fee;
            totalCollected[poolId] += fee;
            emit FeeTaken(poolId, sender, params.zeroForOne, eth, fee);
        }

        return (BaseHook.afterSwap.selector, unspecifiedDelta);
    }

    // ---------------------------------------------------------------------------------------------
    // Donation
    // ---------------------------------------------------------------------------------------------

    /// @notice Donates every ETH fee accrued on `key`'s pool to its in-range liquidity providers.
    /// @dev Permissionless. Burns the pool's claims and calls `PoolManager.donate(key, amount, 0)`.
    /// Reverts `NothingToDonate` when nothing is accrued and `NoLiquidity` while in-range liquidity is zero.
    /// @return amount The ETH amount donated.
    function donateFees(PoolKey calldata key) external returns (uint256 amount) {
        amount = accrued[key.toId()];
        if (amount == 0) revert NothingToDonate();

        assembly ("memory-safe") {
            tstore(DONATING_SLOT, 1)
        }
        poolManager.unlock(abi.encode(key));
        assembly ("memory-safe") {
            tstore(DONATING_SLOT, 0)
        }
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only the PoolManager, and only during an unlock started by `donateFees`.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256 donating;
        assembly ("memory-safe") {
            donating := tload(DONATING_SLOT)
        }
        if (donating == 0) revert NotDonating();

        PoolKey memory key = abi.decode(data, (PoolKey));
        PoolId poolId = key.toId();
        if (poolManager.getLiquidity(poolId) == 0) revert NoLiquidity();

        uint256 amount = accrued[poolId];
        accrued[poolId] = 0;
        totalDonated[poolId] += amount;

        // Burning the claims credits this contract with `amount` ETH inside the PoolManager; the donation
        // debits the same amount. The two net to zero, so the unlock closes without any transfer.
        poolManager.burn(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), amount);
        poolManager.donate(key, amount, 0, "");

        emit FeesDonated(poolId, amount);
        return "";
    }
}
