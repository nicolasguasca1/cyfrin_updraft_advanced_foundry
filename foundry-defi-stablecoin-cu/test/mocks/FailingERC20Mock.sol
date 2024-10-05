// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

contract FailingERC20Mock is ERC20Mock {
    bool public shouldFail;

    constructor(string memory name, string memory symbol, address initialAccount, uint256 initialBalance)
        ERC20Mock()
    {}

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        if (shouldFail) {
            return false;
        }
        return super.transferFrom(sender, recipient, amount);
    }
}