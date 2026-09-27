// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {ETHF} from "../../src/ETHF.sol";
import {ETHOnlyFeeHook} from "../../src/ETHOnlyFeeHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";

/// @notice Shared fixture: a real v4 PoolManager, the ETHF token, the hook mined onto a matching address, the
/// two test routers and the launch pool key (native ETH / ETHF, fee 3000, tick spacing 60).
abstract contract HookTestBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS = HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP | HookFlags.BEFORE_SWAP_RETURN_DELTA
        | HookFlags.AFTER_SWAP_RETURN_DELTA;

    /// @dev Opening price: 1 ETH = ~1,000,000 ETHF. ln(1e6)/ln(1.0001) ~= 138,155; rounded to tick spacing 60.
    int24 internal constant OPENING_TICK = 138_180;
    /// @dev The seed range sits entirely below the opening price and therefore holds only ETHF.
    int24 internal constant SEED_TICK_LOWER = 18_180;
    int24 internal constant SEED_TICK_UPPER = OPENING_TICK;
    /// @dev ~100M ETHF at the chosen range.
    int256 internal constant SEED_LIQUIDITY = 1e23;

    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    IPoolManager internal manager;
    ETHF internal ethf;
    ETHOnlyFeeHook internal hook;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    PoolKey internal key;
    PoolId internal poolId;

    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");

    receive() external payable {}

    function setUp() public virtual {
        manager = IPoolManager(address(new PoolManager(address(this))));
        ethf = new ETHF();
        hook = deployHook(manager);
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(ethf)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        // The "factory" (this contract) holds the whole supply; hand some to the LP and the trader.
        ethf.transfer(lp, 400_000_000 ether);
        ethf.transfer(trader, 100_000_000 ether);
        vm.deal(lp, 1_000 ether);
        vm.deal(trader, 1_000 ether);
        vm.deal(address(this), 1_000 ether);

        vm.prank(lp);
        ethf.approve(address(lpRouter), type(uint256).max);
        vm.prank(trader);
        ethf.approve(address(swapRouter), type(uint256).max);
        ethf.approve(address(swapRouter), type(uint256).max);
        ethf.approve(address(lpRouter), type(uint256).max);
    }

    /// @dev Mines a salt so that CREATE2 places the hook on an address carrying exactly FLAGS, as the deployer
    /// will on Sepolia.
    function deployHook(IPoolManager pm) internal returns (ETHOnlyFeeHook deployed) {
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(ETHOnlyFeeHook).creationCode, abi.encode(pm));
        deployed = new ETHOnlyFeeHook{salt: salt}(pm);
        require(address(deployed) == predicted, "hook address mismatch");
    }

    function openPool() internal {
        manager.initialize(key, TickMath.getSqrtPriceAtTick(OPENING_TICK));
    }

    /// @dev The factory's one-sided ETHF seed: a range entirely below the opening price.
    function seedOneSided() internal returns (BalanceDelta delta) {
        vm.prank(lp);
        delta = lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: SEED_TICK_LOWER, tickUpper: SEED_TICK_UPPER, liquidityDelta: SEED_LIQUIDITY, salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev Two-sided liquidity around the current price so that every swap direction has depth.
    function addTwoSided(int24 width, int256 liquidity) internal returns (BalanceDelta delta) {
        (, int24 tick,,) = _slot0();
        int24 lower = ((tick - width) / 60) * 60;
        int24 upper = ((tick + width) / 60) * 60 + 60;
        vm.prank(lp);
        delta = lpRouter.modifyLiquidity{value: 500 ether}(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liquidity, salt: bytes32(0)}),
            ""
        );
    }

    function _slot0() internal view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) {
        return manager.getSlot0(poolId);
    }

    function swapParams(bool zeroForOne, int256 amountSpecified) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    /// @dev Performs a swap as `who`, returning the swapper's ETH change and the pool's ETH delta from the
    /// PoolManager's `Swap` event.
    function swapAs(address who, SwapParams memory params, uint256 value)
        internal
        returns (int256 swapperEthChange, int256 poolEthDelta, BalanceDelta delta)
    {
        uint256 before = who.balance;
        vm.recordLogs();
        vm.prank(who);
        delta = swapRouter.swap{value: value}(key, params, PoolSwapTest.TestSettings(false, false), "");
        poolEthDelta = _poolAmount0FromLogs(vm.getRecordedLogs());
        swapperEthChange = int256(who.balance) - int256(before);
    }

    function _poolAmount0FromLogs(Vm.Log[] memory logs) internal view returns (int256 amount0) {
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (int128 a0,,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                amount0 = a0;
                found = true;
            }
        }
        require(found, "no Swap event");
    }

    /// @dev The PoolManager wraps hook reverts: WrappedError(hook, callbackSelector, reason, HookCallFailed).
    function hookRevert(bytes4 callback, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function ceilFee(uint256 eth) internal pure returns (uint256) {
        return (eth * 50 + 9_999) / 10_000;
    }
}
