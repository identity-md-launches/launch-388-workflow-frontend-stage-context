// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/src/libraries/FixedPoint128.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {ETHOnlyFeeHook} from "../src/ETHOnlyFeeHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ETHOnlyFeeHookTest is HookTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------------------------------

    function test_permissionsAreExactlyTheFourSwapFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(
            p.beforeInitialize || p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity
                || p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate
                || p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta
        );
        assertEq(FLAGS, 0x00CC);
        assertEq(HookFlags.flagsOf(address(hook)), 0x00CC);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.FEE_BPS(), 50);
        assertEq(hook.BPS_DENOMINATOR(), 10_000);
    }

    function test_deploymentRevertsOnAnAddressWithoutTheFlags() public {
        // Plain CREATE lands on an address with essentially random low bits; the constructor must refuse it.
        // The expected address is unknown here, so match on the selector only.
        vm.expectPartialRevert(Hooks.HookAddressNotValid.selector);
        new ETHOnlyFeeHook(manager);
    }

    function test_feeOnRoundsUp() public view {
        assertEq(hook.feeOn(0), 0);
        assertEq(hook.feeOn(1), 1);
        assertEq(hook.feeOn(199), 1);
        assertEq(hook.feeOn(200), 1);
        assertEq(hook.feeOn(201), 2);
        assertEq(hook.feeOn(1 ether), 0.005 ether);
        assertEq(hook.feeOn(1 ether + 1), 0.005 ether + 1);
    }

    function testFuzz_feeOnMatchesCeil(uint128 eth) public view {
        uint256 fee = hook.feeOn(eth);
        assertEq(fee, ceilFee(eth));
        assertGe(fee * 10_000, uint256(eth) * 50);
        assertLt((fee - (fee > 0 ? 1 : 0)) * 10_000, uint256(eth) * 50 + (fee > 0 ? 0 : 1));
    }

    // ------------------------------------------------------------------------------------------
    // Launch rehearsal: open, one-sided seed, first buy into an ETH-less pool, then a sell
    // ------------------------------------------------------------------------------------------

    function test_launchRehearsal() public {
        openPool();
        assertEq(address(manager).balance, 0);

        BalanceDelta seed = seedOneSided();
        assertEq(seed.amount0(), 0, "seed must not require ETH");
        assertLt(seed.amount1(), 0, "seed must deposit ETHF");
        assertEq(address(manager).balance, 0, "pool holds no ETH before the first buy");
        assertEq(manager.getLiquidity(poolId), 0, "seed sits below the opening price");

        // First buy: 1 ETH exact input.
        uint256 amountIn = 1 ether;
        uint256 fee = ceilFee(amountIn);
        uint256 ethfBefore = ethf.balanceOf(trader);

        vm.expectEmit(true, true, true, true, address(hook));
        emit ETHOnlyFeeHook.FeeTaken(poolId, address(swapRouter), true, amountIn, fee);
        (int256 swapperEth, int256 poolEth,) = swapAs(trader, swapParams(true, -int256(amountIn)), amountIn);

        assertEq(swapperEth, -int256(amountIn), "buyer pays exactly the input");
        assertEq(poolEth, -int256(amountIn - fee), "pool receives the input minus the fee");
        assertEq(swapperEth, poolEth - int256(fee));
        assertGt(ethf.balanceOf(trader), ethfBefore, "buyer received ETHF");
        assertEq(address(manager).balance, amountIn, "all ETH sits in the PoolManager");
        assertEq(manager.balanceOf(address(hook), 0), fee, "fee is held as ERC-6909 claims");
        assertEq(hook.accrued(poolId), fee);
        assertEq(hook.totalCollected(poolId), fee);
        assertEq(hook.totalDonated(poolId), 0);
        assertGt(manager.getLiquidity(poolId), 0, "the buy pushed the price into the seed range");

        // Then a sell: exact input of half the ETHF just bought.
        uint256 sellIn = (ethf.balanceOf(trader) - ethfBefore) / 2;
        (int256 sellerEth, int256 poolEthOut,) = swapAs(trader, swapParams(false, -int256(sellIn)), 0);
        uint256 sellFee = ceilFee(uint256(poolEthOut));
        assertGt(poolEthOut, 0);
        assertEq(sellerEth, poolEthOut - int256(sellFee), "seller receives the pool's ETH minus the fee");
        assertEq(manager.balanceOf(address(hook), 0), fee + sellFee);
        assertEq(hook.accrued(poolId), fee + sellFee);
        assertEq(hook.totalCollected(poolId), fee + sellFee);
    }

    // ------------------------------------------------------------------------------------------
    // The four fee paths: swapper ETH change == pool ETH delta -/+ exactly the fee
    // ------------------------------------------------------------------------------------------

    function _openSeedAndPrime() internal {
        openPool();
        seedOneSided();
        // A first buy so the pool holds ETH and the price is inside liquidity.
        swapAs(trader, swapParams(true, -10 ether), 10 ether);
        addTwoSided(6_000, 5e22);
    }

    function test_pathA_buyExactInput() public {
        _openSeedAndPrime();
        uint256 amountIn = 3 ether;
        uint256 fee = ceilFee(amountIn);
        uint256 claimsBefore = manager.balanceOf(address(hook), 0);

        vm.expectEmit(true, true, true, true, address(hook));
        emit ETHOnlyFeeHook.FeeTaken(poolId, address(swapRouter), true, amountIn, fee);
        (int256 swapperEth, int256 poolEth, BalanceDelta delta) =
            swapAs(trader, swapParams(true, -int256(amountIn)), amountIn);

        assertEq(swapperEth, -int256(amountIn));
        assertEq(poolEth, -int256(amountIn - fee));
        assertEq(swapperEth, poolEth - int256(fee));
        assertEq(delta.amount0(), -int256(amountIn), "router-visible delta includes the fee");
        assertEq(manager.balanceOf(address(hook), 0) - claimsBefore, fee);
    }

    function test_pathB_sellExactOutput() public {
        _openSeedAndPrime();
        uint256 amountOut = 2 ether;
        uint256 fee = ceilFee(amountOut);
        uint256 claimsBefore = manager.balanceOf(address(hook), 0);

        vm.expectEmit(true, true, true, true, address(hook));
        emit ETHOnlyFeeHook.FeeTaken(poolId, address(swapRouter), false, amountOut, fee);
        (int256 swapperEth, int256 poolEth, BalanceDelta delta) =
            swapAs(trader, swapParams(false, int256(amountOut)), 0);

        assertEq(swapperEth, int256(amountOut), "seller receives exactly the amount asked");
        assertEq(poolEth, int256(amountOut + fee), "pool pays the amount plus the fee");
        assertEq(swapperEth, poolEth - int256(fee));
        assertEq(delta.amount0(), int256(amountOut));
        assertEq(manager.balanceOf(address(hook), 0) - claimsBefore, fee);
    }

    function test_pathC_buyExactOutput() public {
        _openSeedAndPrime();
        uint256 ethfOut = 1_000_000 ether;
        uint256 claimsBefore = manager.balanceOf(address(hook), 0);
        uint256 ethfBefore = ethf.balanceOf(trader);

        (int256 swapperEth, int256 poolEth, BalanceDelta delta) =
            swapAs(trader, swapParams(true, int256(ethfOut)), 50 ether);
        uint256 fee = ceilFee(uint256(-poolEth));

        assertLt(poolEth, 0);
        assertEq(swapperEth, poolEth - int256(fee), "buyer pays the pool's ETH plus the fee");
        assertEq(delta.amount0(), swapperEth);
        assertEq(ethf.balanceOf(trader) - ethfBefore, ethfOut, "exact output honoured");
        assertEq(manager.balanceOf(address(hook), 0) - claimsBefore, fee);
        assertEq(hook.accrued(poolId), manager.balanceOf(address(hook), 0));
    }

    function test_pathD_sellExactInput() public {
        _openSeedAndPrime();
        uint256 ethfIn = 1_000_000 ether;
        uint256 claimsBefore = manager.balanceOf(address(hook), 0);

        (int256 swapperEth, int256 poolEth, BalanceDelta delta) = swapAs(trader, swapParams(false, -int256(ethfIn)), 0);
        uint256 fee = ceilFee(uint256(poolEth));

        assertGt(poolEth, 0);
        assertEq(swapperEth, poolEth - int256(fee), "seller receives the pool's ETH minus the fee");
        assertEq(delta.amount0(), swapperEth);
        assertEq(manager.balanceOf(address(hook), 0) - claimsBefore, fee);
    }

    function testFuzz_everyPathChargesExactlyTheFee(uint8 mode, uint96 rawAmount) public {
        _openSeedAndPrime();
        mode = mode % 4;
        int256 amountSpecified;
        bool zeroForOne;
        uint256 value;
        if (mode == 0) {
            uint256 a = bound(rawAmount, 1_000, 20 ether);
            (zeroForOne, amountSpecified, value) = (true, -int256(a), a);
        } else if (mode == 1) {
            uint256 a = bound(rawAmount, 1, 2 ether);
            (zeroForOne, amountSpecified, value) = (false, int256(a), 0);
        } else if (mode == 2) {
            uint256 a = bound(rawAmount, 1e12, 2_000_000 ether);
            (zeroForOne, amountSpecified, value) = (true, int256(a), 100 ether);
        } else {
            uint256 a = bound(rawAmount, 1e15, 5_000_000 ether);
            (zeroForOne, amountSpecified, value) = (false, -int256(a), 0);
        }
        uint256 claimsBefore = manager.balanceOf(address(hook), 0);
        uint256 collectedBefore = hook.totalCollected(poolId);

        (int256 swapperEth, int256 poolEth,) = swapAs(trader, swapParams(zeroForOne, amountSpecified), value);

        uint256 ethBasis = mode == 0 || mode == 1
            ? uint256(amountSpecified < 0 ? -amountSpecified : amountSpecified)
            : uint256(poolEth < 0 ? -poolEth : poolEth);
        uint256 fee = ceilFee(ethBasis);
        assertEq(swapperEth, poolEth - int256(fee), "swapper ETH change == pool ETH delta - fee");
        assertEq(manager.balanceOf(address(hook), 0) - claimsBefore, fee);
        assertEq(hook.totalCollected(poolId) - collectedBefore, fee);
        assertEq(manager.balanceOf(address(hook), 0), hook.totalCollected(poolId) - hook.totalDonated(poolId));
    }

    // ------------------------------------------------------------------------------------------
    // Failure paths
    // ------------------------------------------------------------------------------------------

    function test_partialExactInputBuyReverts() public {
        _openSeedAndPrime();
        (uint160 sqrtPrice, int24 tick,,) = _slot0();
        // A limit just below the current price stops the swap early.
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -5 ether, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tick - 1)
        });
        assertLt(params.sqrtPriceLimitX96, sqrtPrice);
        vm.expectRevert(hookRevert(IHooks.afterSwap.selector, ETHOnlyFeeHook.PartialFill.selector));
        vm.prank(trader);
        swapRouter.swap{value: 5 ether}(key, params, PoolSwapTest.TestSettings(false, false), "");
    }

    function test_partialExactOutputSellReverts() public {
        _openSeedAndPrime();
        (, int24 tick,,) = _slot0();
        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: 5 ether, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tick + 1)
        });
        vm.expectRevert(hookRevert(IHooks.afterSwap.selector, ETHOnlyFeeHook.PartialFill.selector));
        vm.prank(trader);
        swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
    }

    function test_partialFillIsNotCheckedWhenEthIsUnspecified() public {
        _openSeedAndPrime();
        (, int24 tick,,) = _slot0();
        // Exact-output buy with a tight limit: the pool fills what it can, the hook fees whatever ETH moved.
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 50_000_000 ether,
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tick - 30)
        });
        (int256 swapperEth, int256 poolEth,) = swapAs(trader, params, 100 ether);
        assertLt(poolEth, 0);
        assertEq(swapperEth, poolEth - int256(ceilFee(uint256(-poolEth))));
    }

    function test_buyExactInputTooSmallReverts() public {
        _openSeedAndPrime();
        // 1 wei in: fee = ceil(1 * 50 / 10000) = 1, nothing left to swap.
        vm.expectRevert(hookRevert(IHooks.beforeSwap.selector, ETHOnlyFeeHook.SwapTooSmall.selector));
        vm.prank(trader);
        swapRouter.swap{value: 1}(key, swapParams(true, -1), PoolSwapTest.TestSettings(false, false), "");
    }

    function test_buyExactInputOfTwoWeiSucceeds() public {
        _openSeedAndPrime();
        // 2 wei in: fee 1, pool swaps 1 wei.
        (int256 swapperEth, int256 poolEth,) = swapAs(trader, swapParams(true, -2), 2);
        assertEq(swapperEth, -2);
        assertEq(poolEth, -1);
    }

    function test_sellExactInputTooSmallReverts() public {
        _openSeedAndPrime();
        // A tiny ETHF input yields at most a wei or two of ETH; the fee eats it all.
        vm.expectRevert(hookRevert(IHooks.afterSwap.selector, ETHOnlyFeeHook.SwapTooSmall.selector));
        vm.prank(trader);
        swapRouter.swap(key, swapParams(false, -1_000), PoolSwapTest.TestSettings(false, false), "");
    }

    function test_sellExactOutputOfOneWeiSucceeds() public {
        _openSeedAndPrime();
        // The seller receives 1 wei; the pool pays 2, the hook keeps 1.
        (int256 swapperEth, int256 poolEth,) = swapAs(trader, swapParams(false, 1), 0);
        assertEq(swapperEth, 1);
        assertEq(poolEth, 2);
    }

    function test_swapWithoutEnoughEthReverts() public {
        _openSeedAndPrime();
        // The router must settle the input plus the fee; sending only the pool's share is not enough.
        vm.expectRevert();
        vm.prank(trader);
        swapRouter.swap{value: 1 ether - 1}(
            key, swapParams(true, -1 ether), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    function test_hookDataIsIgnored() public {
        _openSeedAndPrime();
        uint256 amountIn = 1 ether;
        uint256 fee = ceilFee(amountIn);
        uint256 before = trader.balance;
        vm.expectEmit(true, true, true, true, address(hook));
        emit ETHOnlyFeeHook.FeeTaken(poolId, address(swapRouter), true, amountIn, fee);
        vm.prank(trader);
        swapRouter.swap{value: amountIn}(
            key, swapParams(true, -int256(amountIn)), PoolSwapTest.TestSettings(false, false), abi.encode(trader, "x")
        );
        assertEq(before - trader.balance, amountIn);
    }

    // ------------------------------------------------------------------------------------------
    // Pools whose currency0 is not native ETH pay nothing
    // ------------------------------------------------------------------------------------------

    function test_nonEthPoolPaysNothing() public {
        MockERC20 a = new MockERC20("A", "A", 1_000_000 ether);
        MockERC20 b = new MockERC20("B", "B", 1_000_000 ether);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        t0.approve(address(lpRouter), type(uint256).max);
        t1.approve(address(lpRouter), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);

        PoolKey memory erc20Key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId erc20Id = erc20Key.toId();
        manager.initialize(erc20Key, TickMath.getSqrtPriceAtTick(0));
        lpRouter.modifyLiquidity(erc20Key, ModifyLiquidityParams(-600, 600, 1e21, bytes32(0)), "");

        uint256 t0Before = t0.balanceOf(address(this));
        uint256 t1Before = t1.balanceOf(address(this));
        BalanceDelta d =
            swapRouter.swap(erc20Key, swapParams(true, -1 ether), PoolSwapTest.TestSettings(false, false), "");
        assertEq(int256(t0.balanceOf(address(this))) - int256(t0Before), d.amount0());
        assertEq(int256(t1.balanceOf(address(this))) - int256(t1Before), d.amount1());
        assertEq(d.amount0(), -1 ether, "no fee on the input");
        swapRouter.swap(erc20Key, swapParams(false, 0.1 ether), PoolSwapTest.TestSettings(false, false), "");
        swapRouter.swap(erc20Key, swapParams(true, 0.1 ether), PoolSwapTest.TestSettings(false, false), "");
        swapRouter.swap(erc20Key, swapParams(false, -0.1 ether), PoolSwapTest.TestSettings(false, false), "");

        assertEq(hook.accrued(erc20Id), 0);
        assertEq(hook.totalCollected(erc20Id), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(t0)))), 0);
        vm.expectRevert(ETHOnlyFeeHook.NothingToDonate.selector);
        hook.donateFees(erc20Key);
    }

    function test_secondEthPoolIsAccountedSeparately() public {
        _openSeedAndPrime();
        MockERC20 other = new MockERC20("O", "O", 1_000_000_000 ether);
        other.approve(address(lpRouter), type(uint256).max);
        other.approve(address(swapRouter), type(uint256).max);
        PoolKey memory key2 = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(other)),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        PoolId id2 = key2.toId();
        manager.initialize(key2, TickMath.getSqrtPriceAtTick(0));
        lpRouter.modifyLiquidity{value: 100 ether}(key2, ModifyLiquidityParams(-600, 600, 1e21, bytes32(0)), "");

        uint256 accrued1 = hook.accrued(poolId);
        swapRouter.swap{value: 1 ether}(key2, swapParams(true, -1 ether), PoolSwapTest.TestSettings(false, false), "");
        assertEq(hook.accrued(id2), ceilFee(1 ether));
        assertEq(hook.accrued(poolId), accrued1, "other pool untouched");
        assertEq(manager.balanceOf(address(hook), 0), accrued1 + ceilFee(1 ether));

        // Donating one pool leaves the other's claims in place.
        hook.donateFees(key2);
        assertEq(hook.accrued(id2), 0);
        assertEq(hook.totalDonated(id2), ceilFee(1 ether));
        assertEq(manager.balanceOf(address(hook), 0), accrued1);
    }

    // ------------------------------------------------------------------------------------------
    // Donation
    // ------------------------------------------------------------------------------------------

    function test_donateFeesRaisesInRangeFeeGrowthByExactlyTheAmount() public {
        _openSeedAndPrime();
        uint256 amount = hook.accrued(poolId);
        assertGt(amount, 0);
        uint128 liquidity = manager.getLiquidity(poolId);
        (uint256 growth0Before, uint256 growth1Before) = manager.getFeeGrowthGlobals(poolId);
        uint256 managerEthBefore = address(manager).balance;

        vm.expectEmit(true, true, true, true, address(hook));
        emit ETHOnlyFeeHook.FeesDonated(poolId, amount);
        vm.prank(makeAddr("anyone"));
        uint256 donated = hook.donateFees(key);

        (uint256 growth0After, uint256 growth1After) = manager.getFeeGrowthGlobals(poolId);
        assertEq(donated, amount);
        assertEq(growth0After - growth0Before, FullMath.mulDiv(amount, FixedPoint128.Q128, liquidity));
        assertEq(growth1After, growth1Before, "currency1 growth untouched");
        assertEq(hook.accrued(poolId), 0);
        assertEq(hook.totalDonated(poolId), amount);
        assertEq(hook.totalCollected(poolId), amount);
        assertEq(manager.balanceOf(address(hook), 0), 0, "claims burned");
        assertEq(address(manager).balance, managerEthBefore, "no ETH moved");
    }

    function test_donatedEthIsCollectableByTheInRangeLp() public {
        openPool();
        seedOneSided();
        swapAs(trader, swapParams(true, -10 ether), 10 ether);
        // After the first buy the seed position is the only in-range liquidity.
        uint256 amount = hook.accrued(poolId);
        hook.donateFees(key);

        // Poke the position with a zero liquidity change to collect fees.
        uint256 lpEthBefore = lp.balance;
        vm.prank(lp);
        BalanceDelta d =
            lpRouter.modifyLiquidity(key, ModifyLiquidityParams(SEED_TICK_LOWER, SEED_TICK_UPPER, 0, bytes32(0)), "");
        // The position receives the donation plus the LP fee on the swap, minus at most 1 wei of rounding.
        assertGe(uint256(int256(d.amount0())), amount - 1);
        assertEq(lp.balance - lpEthBefore, uint256(int256(d.amount0())));
    }

    function test_donateFeesRevertsWithNoLiquidityInRange() public {
        _openSeedAndPrime();
        assertGt(hook.accrued(poolId), 0);
        // Remove every position, then the in-range liquidity is zero.
        vm.startPrank(lp);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(SEED_TICK_LOWER, SEED_TICK_UPPER, -SEED_LIQUIDITY, bytes32(0)), ""
        );
        (, int24 tick,,) = _slot0();
        int24 lower = ((tick - 6_000) / 60) * 60;
        int24 upper = ((tick + 6_000) / 60) * 60 + 60;
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, -5e22, bytes32(0)), "");
        vm.stopPrank();
        assertEq(manager.getLiquidity(poolId), 0);

        uint256 amount = hook.accrued(poolId);
        vm.expectRevert(ETHOnlyFeeHook.NoLiquidity.selector);
        hook.donateFees(key);
        assertEq(hook.accrued(poolId), amount, "claims wait for a later call");
        assertEq(manager.balanceOf(address(hook), 0), amount);

        // Liquidity comes back, the waiting claims can be donated.
        vm.prank(lp);
        lpRouter.modifyLiquidity{value: 100 ether}(key, ModifyLiquidityParams(lower, upper, 1e22, bytes32(0)), "");
        assertEq(hook.donateFees(key), amount);
        assertEq(hook.accrued(poolId), 0);
    }

    function test_donateFeesRevertsWhenNothingAccrued() public {
        openPool();
        seedOneSided();
        vm.expectRevert(ETHOnlyFeeHook.NothingToDonate.selector);
        hook.donateFees(key);
    }

    function test_donateFeesRevertsForAnUninitialisedPool() public {
        vm.expectRevert(ETHOnlyFeeHook.NothingToDonate.selector);
        hook.donateFees(key);
    }

    function test_donateTwiceRequiresNewFees() public {
        _openSeedAndPrime();
        hook.donateFees(key);
        vm.expectRevert(ETHOnlyFeeHook.NothingToDonate.selector);
        hook.donateFees(key);
        swapAs(trader, swapParams(true, -1 ether), 1 ether);
        assertEq(hook.donateFees(key), ceilFee(1 ether));
    }

    // ------------------------------------------------------------------------------------------
    // Access control
    // ------------------------------------------------------------------------------------------

    function test_callbacksRefuseNonPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, swapParams(true, -1 ether), "");
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(address(this), key, swapParams(true, -1 ether), BalanceDelta.wrap(0), "");
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(key));
    }

    function test_unlockCallbackRefusesPoolManagerOutsideDonateFees() public {
        _openSeedAndPrime();
        // Someone else unlocking the manager cannot route a callback into the hook, and even a direct call
        // from the manager's address outside donateFees is refused.
        vm.prank(address(manager));
        vm.expectRevert(ETHOnlyFeeHook.NotDonating.selector);
        hook.unlockCallback(abi.encode(key));
    }

    function test_unlockCallbackViaForeignUnlockIsRefused() public {
        _openSeedAndPrime();
        ForeignUnlocker attacker = new ForeignUnlocker(manager, hook);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        attacker.attack(key);
        assertEq(hook.accrued(poolId), manager.balanceOf(address(hook), 0));
    }

    function test_hookHoldsNoEthAndHasNoReceive() public {
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok, "hook must not accept ETH");
        assertEq(address(hook).balance, 0);
    }

    function test_noAdminSurface() public {
        string[6] memory sigs = [
            "setFee(uint256)",
            "setFeeBps(uint256)",
            "transferOwnership(address)",
            "owner()",
            "withdraw(address,uint256)",
            "collect(address)"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(sigs[i], address(0xBEEF), uint256(1)));
            assertFalse(ok, sigs[i]);
        }
    }
}

/// @dev Unlocks the PoolManager itself and, from inside its own callback, tries to make the hook believe it is
/// donating. The hook's callback must refuse because the unlock was not started by `donateFees`.
contract ForeignUnlocker {
    IPoolManager immutable manager;
    ETHOnlyFeeHook immutable hook;

    constructor(IPoolManager m, ETHOnlyFeeHook h) {
        manager = m;
        hook = h;
    }

    function attack(PoolKey calldata key) external {
        manager.unlock(abi.encode(key));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        hook.unlockCallback(data);
        return "";
    }
}
