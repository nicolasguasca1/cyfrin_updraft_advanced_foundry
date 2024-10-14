// SPDX-License-Identifier: MIT
// Have our invariant aka properties

// What are the invariats?

// 1. The total supply of DSC token should always be less than the total value of collateral
// 2. Getter view functions should never revert <- evergreen invariant

// Future work. The total supply of DSC token is always equal to the sum of the balances of all accounts.

pragma solidity ^0.8.20;

import {Test, console} from "lib/forge-std/src/Test.sol";
import {StdInvariant} from "lib/forge-std/src/StdInvariant.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

import {Handler} from "./Handler.t.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract Invariants is StdInvariant, Test {
    // Set up the state of the contract before each test
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;

    uint256 MAX_PRICE_SIZE = type(uint96).max;
    // additional precision
    uint256 constant PRECISION = 1e18;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,,weth,wbtc,) = config.activeNetworkConfig();
        console.log("DSCEngine Address: ", address(dsce));
        // console the total supply of DSC
        console.log("INITIAL Total Supply: ", dsc.totalSupply());
        console.log("dsc Address: ", address(dsc));
        handler = new Handler(dsce, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        // get the value of all the collateral in the protocol
        // compare it to all the debt (dsc)
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        // Ensure values are not zero
        if (totalWethDeposited == 0) {
            totalWethDeposited = 1;
        }
        if (totalWbtcDeposited == 0) {
            totalWbtcDeposited = 1;
        }
        
        // totalWethDeposited = bound(totalWethDeposited, 1, MAX_PRICE_SIZE);
        // totalWbtcDeposited = bound(totalWbtcDeposited, 1, MAX_PRICE_SIZE);
        // console.log("Total WETH Deposited: ", totalWethDeposited);
        // console.log("Total WBTC Deposited: ", totalWbtcDeposited);

        uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("WETH Value: ", wethValue);
        console.log("WBTC Value: ", wbtcValue);
        console.log("Total Supply: ", totalSupply);

        console.log(" Times mint called: ", handler.timesMintIsCalled());
        // uint256 reduced = totalSupply/PRECISION;
        assert (wethValue + wbtcValue >= totalSupply);
    }

    function invariant_getterFunctionsShouldNotRevert() public view {
        uint256 totalSupply = dsc.totalSupply();
        dsce.getAccountCollateralValue(msg.sender);
        dsce.getAccountInformation(msg.sender);
        dsce.getAdditionalFeedPrecision();
        dsce.getCollateralBalanceOfUser(msg.sender,weth);
        dsce.getCollateralBalanceOfUser(msg.sender,wbtc);
        dsce.getCollateralTokenPriceFeed(weth);
        dsce.getCollateralTokenPriceFeed(wbtc);
        dsce.getCollateralTokens();
        dsce.getDsc();
        dsce.getHealthFactor(msg.sender);
        dsce.getLiquidationBonus();
        dsce.getLiquidationPrecision();
        dsce.getLiquidationThreshold();
        dsce.getMinHealthFactor();
        dsce.getPrecision();
        // Ensure values are not zero
        if (totalSupply == 0) {
            totalSupply = 1;
        }
        dsce.getTokenAmountFromUsd(weth,totalSupply);
        dsce.getTokenAmountFromUsd(wbtc,totalSupply);

        // Check if the getter functions revert
        dsce.getUsdValue(weth, totalSupply);
        dsce.getUsdValue(wbtc, totalSupply);
    }
}