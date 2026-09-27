// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {ETHF} from "../src/ETHF.sol";
import {ETHOnlyFeeHook} from "../src/ETHOnlyFeeHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @title Deploy
/// @notice Reference deployment for a rehearsal. The production launch goes through the launch factory
/// described in the README, which deploys both contracts itself; this script only documents the exact steps
/// (CREATE2 salt mining for the hook's permission bits, the single PoolManager constructor argument) and lets
/// tests exercise them without an RPC.
/// @dev No environment variables are read. Every parameter is a constant or a function argument.
contract Deploy is Script {
    /// @notice Uniswap v4 PoolManager on Sepolia (chain id 11155111).
    IPoolManager public constant SEPOLIA_POOL_MANAGER = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    /// @notice The deterministic CREATE2 proxy that `forge script` uses for `new X{salt: s}()`.
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// @notice beforeSwap | afterSwap | beforeSwapReturnDelta | afterSwapReturnDelta == 0x00CC.
    uint160 public constant HOOK_FLAGS = HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    /// @notice Mines a salt so that `deployer` places the hook on an address carrying HOOK_FLAGS.
    function mineSalt(address deployer, IPoolManager poolManager)
        public
        view
        returns (address hookAddress, bytes32 salt)
    {
        return HookMiner.find(deployer, HOOK_FLAGS, type(ETHOnlyFeeHook).creationCode, abi.encode(poolManager));
    }

    /// @notice Deploys the token and the hook with an already mined salt. Pure deployment logic; tests call it.
    function deploy(IPoolManager poolManager, bytes32 salt) public returns (ETHF token, ETHOnlyFeeHook hook) {
        token = new ETHF();
        hook = new ETHOnlyFeeHook{salt: salt}(poolManager);
        require(HookFlags.matches(address(hook), HOOK_FLAGS), "hook address does not carry the flags");
    }

    /// @notice Rehearsal entry point for Sepolia. Broadcasts with whatever sender the CLI supplies.
    function run() external returns (ETHF token, ETHOnlyFeeHook hook) {
        (, bytes32 salt) = mineSalt(CREATE2_DEPLOYER, SEPOLIA_POOL_MANAGER);
        vm.startBroadcast();
        (token, hook) = deploy(SEPOLIA_POOL_MANAGER, salt);
        vm.stopBroadcast();
    }
}
