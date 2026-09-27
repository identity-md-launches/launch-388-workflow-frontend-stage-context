// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {ETHF} from "../src/ETHF.sol";
import {ETHOnlyFeeHook} from "../src/ETHOnlyFeeHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

contract DeployTest is Test {
    Deploy deployer;
    IPoolManager manager;

    function setUp() public {
        deployer = new Deploy();
        manager = IPoolManager(address(new PoolManager(address(this))));
    }

    function test_constants() public view {
        assertEq(address(deployer.SEPOLIA_POOL_MANAGER()), 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
        assertEq(deployer.HOOK_FLAGS(), 0x00CC);
    }

    function test_deployPlacesHookOnFlaggedAddress() public {
        (address predicted, bytes32 salt) = deployer.mineSalt(address(deployer), manager);
        (ETHF token, ETHOnlyFeeHook hook) = deployer.deploy(manager, salt);

        assertEq(address(hook), predicted);
        assertTrue(HookFlags.matches(address(hook), 0x00CC));
        assertEq(address(hook.poolManager()), address(manager));
        // The script contract is the deployer here, so it holds the supply; the factory does in production.
        assertEq(token.balanceOf(address(deployer)), token.TOTAL_SUPPLY());
    }

    function test_deployWithWrongSaltReverts() public {
        vm.expectRevert();
        deployer.deploy(manager, bytes32(uint256(123456789)));
    }

    function test_saltIsReproducibleForTheSameDeployerAndManager() public view {
        (address a1, bytes32 s1) = deployer.mineSalt(deployer.CREATE2_DEPLOYER(), deployer.SEPOLIA_POOL_MANAGER());
        (address a2, bytes32 s2) = deployer.mineSalt(deployer.CREATE2_DEPLOYER(), deployer.SEPOLIA_POOL_MANAGER());
        assertEq(a1, a2);
        assertEq(s1, s2);
        assertTrue(HookFlags.matches(a1, 0x00CC));
    }
}
