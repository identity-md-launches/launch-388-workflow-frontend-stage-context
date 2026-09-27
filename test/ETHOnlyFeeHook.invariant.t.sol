// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookTestBase} from "./utils/HookTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ETHOnlyFeeHook} from "../src/ETHOnlyFeeHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Drives two ETH pools (and one ERC-20/ERC-20 pool that must never pay) through every swap mode,
/// donations, and liquidity changes. Reverts (limits, dust, no liquidity) are expected and tolerated.
contract Handler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager immutable manager;
    ETHOnlyFeeHook immutable hook;
    PoolSwapTest immutable swapRouter;
    PoolModifyLiquidityTest immutable lpRouter;
    PoolKey[] public keys;
    PoolKey public erc20Key;

    uint256 public swaps;
    uint256 public donations;
    uint256 public calls;

    receive() external payable {}

    constructor(
        IPoolManager m,
        ETHOnlyFeeHook h,
        PoolSwapTest s,
        PoolModifyLiquidityTest l,
        PoolKey memory k0,
        PoolKey memory k1,
        PoolKey memory kErc20
    ) {
        manager = m;
        hook = h;
        swapRouter = s;
        lpRouter = l;
        keys.push(k0);
        keys.push(k1);
        erc20Key = kErc20;
    }

    function poolCount() external view returns (uint256) {
        return keys.length;
    }

    function _key(uint256 seed) internal view returns (PoolKey memory) {
        return keys[seed % keys.length];
    }

    function _params(uint8 mode, uint256 amount) internal pure returns (SwapParams memory p, uint256 value) {
        mode = mode % 4;
        if (mode == 0) {
            amount = bound(amount, 1_000, 5 ether);
            p = SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1);
            value = amount;
        } else if (mode == 1) {
            amount = bound(amount, 1, 1 ether);
            p = SwapParams(false, int256(amount), TickMath.MAX_SQRT_PRICE - 1);
        } else if (mode == 2) {
            amount = bound(amount, 1e12, 20 ether);
            p = SwapParams(true, int256(amount), TickMath.MIN_SQRT_PRICE + 1);
            value = 25 ether;
        } else {
            amount = bound(amount, 1e12, 20 ether);
            p = SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1);
        }
    }

    function swap(uint256 poolSeed, uint8 mode, uint256 amount) external {
        calls++;
        (SwapParams memory p, uint256 value) = _params(mode, amount);
        try swapRouter.swap{value: value}(_key(poolSeed), p, PoolSwapTest.TestSettings(false, false), "") {
            swaps++;
        } catch {}
    }

    function swapErc20(uint8 mode, uint256 amount) external {
        (SwapParams memory p,) = _params(mode, amount);
        try swapRouter.swap(erc20Key, p, PoolSwapTest.TestSettings(false, false), "") {} catch {}
    }

    function donate(uint256 poolSeed) external {
        try hook.donateFees(_key(poolSeed)) {
            donations++;
        } catch {}
    }

    function addLiquidity(uint256 poolSeed, uint128 liquidity) external {
        PoolKey memory k = _key(poolSeed);
        (, int24 tick,,) = manager.getSlot0(k.toId());
        int24 lower = (tick / 60) * 60 - 1_200;
        int24 upper = (tick / 60) * 60 + 1_260;
        liquidity = uint128(bound(liquidity, 1e18, 1e22));
        try lpRouter.modifyLiquidity{value: 100 ether}(
            k, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), bytes32(uint256(1))), ""
        ) {}
            catch {}
    }

    function removeSeed(uint256 poolSeed, uint128 liquidity) external {
        PoolKey memory k = _key(poolSeed);
        liquidity = uint128(bound(liquidity, 1, 1e22));
        try lpRouter.modifyLiquidity(
            k, ModifyLiquidityParams(-1_200, 1_260, -int256(uint256(liquidity)), bytes32(0)), ""
        ) {}
            catch {}
    }
}

contract ETHOnlyFeeHookInvariantTest is HookTestBase {
    using PoolIdLibrary for PoolKey;

    Handler handler;
    PoolKey key2;
    PoolKey erc20Key;

    function setUp() public override {
        super.setUp();

        MockERC20 other = new MockERC20("Other", "OTH", 1_000_000_000 ether);
        MockERC20 a = new MockERC20("A", "A", 1_000_000_000 ether);
        MockERC20 b = new MockERC20("B", "B", 1_000_000_000 ether);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);

        // Pool 1 is the launch pool but opened at 1:1 so that both directions have depth right away.
        key = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(ethf)), 3_000, 60, IHooks(address(hook)));
        key2 = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(other)), 3_000, 60, IHooks(address(hook)));
        erc20Key = PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 3_000, 60, IHooks(address(hook)));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        manager.initialize(key2, TickMath.getSqrtPriceAtTick(0));
        manager.initialize(erc20Key, TickMath.getSqrtPriceAtTick(0));

        handler = new Handler(manager, hook, swapRouter, lpRouter, key, key2, erc20Key);
        vm.deal(address(handler), 1_000_000 ether);
        ethf.transfer(address(handler), 300_000_000 ether);
        other.transfer(address(handler), 300_000_000 ether);
        t0.transfer(address(handler), 300_000_000 ether);
        t1.transfer(address(handler), 300_000_000 ether);
        vm.startPrank(address(handler));
        ethf.approve(address(swapRouter), type(uint256).max);
        ethf.approve(address(lpRouter), type(uint256).max);
        other.approve(address(swapRouter), type(uint256).max);
        other.approve(address(lpRouter), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t0.approve(address(lpRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(lpRouter), type(uint256).max);
        // Seed every pool with two-sided liquidity around the price.
        // ~61,000 ETH and ~58,000 tokens of depth per pool at the 1:1 opening price.
        lpRouter.modifyLiquidity{value: 100_000 ether}(key, ModifyLiquidityParams(-1_200, 1_260, 1e24, bytes32(0)), "");
        lpRouter.modifyLiquidity{value: 100_000 ether}(key2, ModifyLiquidityParams(-1_200, 1_260, 1e24, bytes32(0)), "");
        lpRouter.modifyLiquidity(erc20Key, ModifyLiquidityParams(-1_200, 1_260, 1e24, bytes32(0)), "");
        vm.stopPrank();

        targetContract(address(handler));
    }

    function _sumAccrued() internal view returns (uint256 total, uint256 net) {
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks h) = handler.keys(i);
            PoolId id = PoolKey(c0, c1, fee, spacing, h).toId();
            total += hook.accrued(id);
            net += hook.totalCollected(id) - hook.totalDonated(id);
        }
    }

    /// @notice ETH claims held == sum over pools of totalCollected - totalDonated == sum of accrued.
    function invariant_claimsMatchAccounting() public view {
        (uint256 total, uint256 net) = _sumAccrued();
        assertEq(manager.balanceOf(address(hook), 0), net, "claims != collected - donated");
        assertEq(total, net, "accrued != collected - donated");
    }

    /// @notice The hook never holds ETH itself, and never earns claims on anything but ETH.
    function invariant_hookNeverHoldsEthOrOtherClaims() public view {
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(ethf)))), 0);
        assertEq(hook.totalCollected(erc20Key.toId()), 0, "ERC-20 pool paid a fee");
    }

    /// @dev Runs once per campaign on the last run's state. A run that attempted several swaps must have
    /// landed most of them, otherwise the invariants above would be checked against an idle pool.
    function afterInvariant() public view {
        uint256 attempts = handler.calls();
        if (attempts >= 4) assertGe(handler.swaps() * 2, attempts, "most swap attempts reverted");
    }

    /// @notice Every ETH the PoolManager holds is backed: claims never exceed its balance.
    function invariant_claimsAreBackedByPoolManagerEth() public view {
        assertLe(manager.balanceOf(address(hook), 0), address(manager).balance);
    }
}
