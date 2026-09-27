// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ETHF} from "../src/ETHF.sol";

contract ETHFTest is Test {
    ETHF token;
    address deployer = address(this);

    function setUp() public {
        token = new ETHF();
    }

    function test_metadata() public view {
        assertEq(token.name(), "ETH Fee");
        assertEq(token.symbol(), "ETHF");
        assertEq(token.decimals(), 18);
    }

    function test_mintsWholeSupplyToDeployer() public view {
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(deployer), 1_000_000_000 ether);
    }

    function test_deployerIsMsgSender() public {
        address factory = makeAddr("factory");
        vm.prank(factory);
        ETHF t = new ETHF();
        assertEq(t.balanceOf(factory), t.totalSupply());
        assertEq(t.balanceOf(address(this)), 0);
    }

    function test_transferMovesExactAmount(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, token.totalSupply());
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), token.TOTAL_SUPPLY() - amount);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    function test_transferBeyondBalanceReverts() public {
        address to = makeAddr("to");
        uint256 tooMuch = token.totalSupply() + 1;
        vm.expectRevert();
        token.transfer(to, tooMuch);
    }

    function test_noMintOrAdminEntryPoints() public {
        string[8] memory sigs = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "transferOwnership(address)",
            "setOwner(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], address(0xBEEF), uint256(1)));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += op - 0x5F;
                continue;
            }
            assertTrue(op != 0xF4 && op != 0xF2 && op != 0xFF);
        }
    }
}
