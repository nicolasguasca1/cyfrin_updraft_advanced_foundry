// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/DecentralizedStableCoin.sol";

contract FailingDecentralizedStableCoin is DecentralizedStableCoin {
    bool public shouldFail;

    constructor() DecentralizedStableCoin() {}

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    function mint(address account, uint256 amount) public override returns (bool) {
        if (shouldFail) {
            return false;
        }
        return super.mint(account, amount);
    }
}