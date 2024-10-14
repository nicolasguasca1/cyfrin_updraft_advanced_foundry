// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/**
 * @title OracleLib
 * @author Patrick Collins
 * @notice This library is used to check the Chainlink Oracle for stale data.
 * If a price is stale, the function will revert, and render the DSCEngine unusable - this is by design.
 * We want the DSCEngine to freeze if prices become stale
 * so if the Chainlink network explodes and you have a lot of money locked in the protocol...
 * @dev OracleLib is a library that provides a simple interface to the Oracle contract.
 */

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

library OracleLib {
    error OracleLib__StalePrice();

    uint256 private constant TIMEOUT = 3 hours; // 3 * 60 * 60 = 10800 seconds
    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundID, int256 answer, uint256 startedAt, uint256 updateAt, uint80 answeredInRound) =
        priceFeed.latestRoundData();

        uint256 secondsSince = block.timestamp - updateAt;
        if (secondsSince > TIMEOUT) {
            revert OracleLib__StalePrice();
        }
        return (roundID, answer, startedAt, updateAt, answeredInRound);
    }
}