// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract ERC20Mock is ERC20 {
    constructor() ERC20("ERC20Mock", "E20M") {}

    function mint(address account, uint256 amount) virtual public returns (bool result) {
        _mint(account, amount);
        return result;
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}
