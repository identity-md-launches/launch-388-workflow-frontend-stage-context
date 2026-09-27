// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title ETH Fee (ETHF)
/// @notice Fixed-supply launch token. The whole supply is minted once, to the deployer, in the constructor.
/// @dev No constructor arguments, no owner, no mint or burn entry points, no proxy. The factory that deploys
/// this contract becomes the holder of the full supply and splits it from there. Standard OpenZeppelin ERC-20
/// semantics: `transfer` moves exactly the requested amount and never changes `totalSupply`.
contract ETHF is ERC20 {
    /// @notice 1,000,000,000 ETHF with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("ETH Fee", "ETHF") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
