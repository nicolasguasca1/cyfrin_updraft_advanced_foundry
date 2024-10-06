// SPDX-License-Identifier: MIT 

pragma solidity 0.8.20;

import {console} from "lib/forge-std/src/console.sol";


import {Test} from "lib/forge-std/src/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

import {FailingERC20Mock} from "../mocks/FailingERC20Mock.sol";
import {FailingDecentralizedStableCoin} from "../mocks/FailingDecentralizedStableCoin.sol";

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";


contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether; // In wei it would be 10e18 
    uint256 public constant AMOUNT_DSC = 10000e18;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc,dsce,config) = deployer.run();
        (ethUsdPriceFeed,btcUsdPriceFeed,weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(address(this), STARTING_ERC20_BALANCE *2); // Has to be double for the liquidate test
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses,priceFeedAddresses,address(dsc));
    }


    ///////////////////////
    // Price Test /////////
    ///////////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/ETH = 30,000e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100;
        uint256 usdAmountInWei = usdAmount * 1e18;
        // $2,000 / ETH, $100
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmountInWei);
        assertEq(expectedWeth, actualWeth);
    }

    ////////////////////////////////////
    // depositCollateral Tests /////////
    ////////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);   
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        // ERC20Mock ranToken = new ERC20Mock("RAN","RAN",USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector,ranToken));
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        // Fund the address with collateral

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL); // 10 ether
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        // At this point dscr cannot deposit more collateral because it has already deposited the maximum amount
        console.log("Allowance of WETH to DSCEngine", ERC20Mock(weth).allowance(USER, address(dsce))/1e18);
        vm.stopPrank();
        _;
    }

    //modifier to mint DSC
    modifier mintedDsc() {
        vm.startPrank(USER);
        uint256 amountDscToMint = AMOUNT_DSC; // 10000e18;
        // Approve the amount of DSC Token to the DSCEngine
        DecentralizedStableCoin(dsc).approve(address(dsce), amountDscToMint);
        dsce.mintDsc(amountDscToMint);
        // Console the allowances
        console.log("Allowance of DSC to DSCEngine", DecentralizedStableCoin(dsc).allowance(USER, address(dsce))/1e18);

        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        console.log("totalDscMinted", totalDscMinted/1e18);
        console.log("collateralValueInUsd", collateralValueInUsd/1e18);

        // 10.000000000000000000 eth as colateral
        // 100000000000.00000000000000000000000000
        uint256 expectedTotalDscMinted = 0;
        console.log("expectedTotalDscMinted", expectedTotalDscMinted/1e18);
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        console.log("expectedDepositAmount", expectedDepositAmount/1e18);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);

    }

    ////////////////////////////////////
    // mintDsc Tests ///////////////////
    ////////////////////////////////////

    function testRevertsIfMintZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintBreaksHealthFactor() public depositedCollateral {
        vm.startPrank(USER);
        uint256 amountDscToMint = 10001e18; // Large amount to break health factor
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 999900009999000099));
        dsce.mintDsc(amountDscToMint);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.startPrank(USER);
        uint256 amountDscToMint = 1e18; // 1 DSC
        dsce.mintDsc(amountDscToMint);
        (uint256 totalDscMinted, ) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, amountDscToMint);
        vm.stopPrank();
    }

    ////////////////////////////////////
    // redeemCollateral Tests /////////
    ////////////////////////////////////

    function testRevertsIfRedeemZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
        assertEq(collateralValueInUsd, AMOUNT_DSC*2);
        vm.stopPrank();
    }

    ////////////////////////////////////
    // burnDsc Tests ///////////////////
    ////////////////////////////////////

    function testRevertsIfBurnZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testCanBurnDsc() public depositedCollateral mintedDsc {
        vm.startPrank(USER);
        uint256 amountDscToMint = AMOUNT_DSC; // 10000e18 -> 10,000 DSC
        dsce.burnDsc(amountDscToMint);
        (uint256 totalDscMinted, ) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
        vm.stopPrank();
    }

    function testBurnDscWithInsufficientBalance() public {
        // ********************GETTING THINGS READY **************************** */

        // Deposit collateral and mint DSC

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL); // 10 ether
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL); // 10 ether
        // At this point dsce cannot deposit more collateral because it has already deposited the maximum amount
        console.log("Allowance of DSC coming from tester burner to DSCEngine", ERC20Mock(weth).allowance(address(this), address(dsce))/1e18);

        // Approve the tokens this contract is about to liquidate
        uint256 amountDscToMint = (AMOUNT_DSC/10000)*2; // 2e18;
        // Approve the amount of DSC Token to the DSCEngine
        DecentralizedStableCoin(dsc).approve(address(dsce), amountDscToMint);
        console.log("Just before next stepi");
        dsce.mintDsc(amountDscToMint/2);
        // Console the allowances
        console.log("Allowance of DSC coming from tester burnes to DSCEngine", DecentralizedStableCoin(dsc).allowance(address(this), address(dsce))/1e18);

        // ************************************************ */


        // vm.startPrank(USER);
        // ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        // dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        // dsce.mintDsc(1e18); // Mint a small amount of DSC
        // dsce.burnDsc(1e18); 
        console.log("Was able to burn");
        vm.expectRevert();
        // vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        dsce.burnDsc(2e18); // Attempt to burn more than minted
        // vm.stopPrank();
    }

    ////////////////////////////////////
    // liquidation Tests ///////////////
    ////////////////////////////////////

    function testRevertsIfLiquidateHealthyPosition() public depositedCollateral mintedDsc {
        vm.startPrank(address(this));
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, AMOUNT_DSC); // 10,000e18
        vm.stopPrank();
    }

    function testRevertsIfLiquidateLessThanNecessary() public depositedCollateral mintedDsc {
        // At this point of the test, $10,000 DSC has been minted with 10 ether collateral
        // Manipulate price feed to make USER's position unhealthy
        int256 newPrice = 2000e8/2; // Lower price to make position unhealthy
        vm.mockCall(ethUsdPriceFeed, abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector), abi.encode(0, newPrice, 0, 0, 0));
        // According to the new price, the collateral value is now $5,000
        // The total DSC minted is $10,000
        // The health factor is 0.5

        // ********************GETTING THINGS READY FOR LIQUIDATOR **************************** */

        // Deposit collateral and mint DSC

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL*2); // 20 ether
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL*2); // 20 ether
        // At this point dsce cannot deposit more collateral because it has already deposited the maximum amount
        console.log("Allowance of DSC coming from liquidator1 to DSCEngine", ERC20Mock(weth).allowance(address(this), address(dsce))/1e18);

        // Approve the tokens this contract is about to liquidate
        uint256 amountDscToMint = AMOUNT_DSC; // 10000e18;
        // Approve the amount of DSC Token to the DSCEngine
        DecentralizedStableCoin(dsc).approve(address(dsce), amountDscToMint);
        console.log("Just before next step");
        dsce.mintDsc(amountDscToMint);
        // Console the allowances
        console.log("Allowance of DSC coming from liquidator to DSCEngine", DecentralizedStableCoin(dsc).allowance(address(this), address(dsce))/1e18);

        // ************************************************ */

        // Liquidate USER's position
        vm.startPrank(address(this));
        // Check allowance before liquidation
        uint256 allowanceBeforeLiquidation = DecentralizedStableCoin(dsc).allowance(USER, address(dsce));
        console.log("Allowance of DSC to DSCEngine before liquidation:", allowanceBeforeLiquidation/1e18);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        uint256 endingUserHealthFactor = dsce.liquidate(weth, USER, (AMOUNT_DSC/2)); // 10,000e18 / 2 = 5,000e18  
        vm.stopPrank();
    }

    // function testCanLiquidateUnhealthyPosition() public depositedCollateral mintedDsc {
    //     // At this point of the test, $10,000 DSC has been minted with 10 ether collateral
    //     // Manipulate price feed to make USER's position unhealthy
    //     int256 newPrice = 2000e8/2; // Lower price to make position unhealthy
    //     vm.mockCall(ethUsdPriceFeed, abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector), abi.encode(0, newPrice, 0, 0, 0));
    //     // According to the new price, the collateral value is now $5,000
    //     // The total DSC minted is $10,000
    //     // The health factor is 0.5

    //     // ********************GETTING THINGS READY FOR LIQUIDATOR **************************** */

    //     // Deposit collateral and mint DSC

    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL*2); // 20 ether
    //     dsce.depositCollateral(weth, AMOUNT_COLLATERAL*2); // 20 ether
    //     // At this point dsce cannot deposit more collateral because it has already deposited the maximum amount
    //     console.log("Allowance of DSC coming from liquidator1 to DSCEngine", ERC20Mock(weth).allowance(address(this), address(dsce))/1e18);

    //     // Approve the tokens this contract is about to liquidate
    //     uint256 amountDscToMint = AMOUNT_DSC; // 10000e18;
    //     // Approve the amount of DSC Token to the DSCEngine
    //     DecentralizedStableCoin(dsc).approve(address(dsce), amountDscToMint);
    //     console.log("Just before next step");
    //     dsce.mintDsc(amountDscToMint);
    //     // Console the allowances
    //     console.log("Allowance of DSC coming from liquidator to DSCEngine", DecentralizedStableCoin(dsc).allowance(address(this), address(dsce))/1e18);

    //     // ************************************************ */

    //     // Liquidate USER's position
    //     vm.startPrank(address(this));
    //     // Check allowance before liquidation
    //     uint256 allowanceBeforeLiquidation = DecentralizedStableCoin(dsc).allowance(USER, address(dsce));
    //     console.log("Allowance of DSC to DSCEngine before liquidation:", allowanceBeforeLiquidation/1e18);

    //     uint256 endingUserHealthFactor = dsce.liquidate(weth, USER, 7250e18); // 10,000e18 / 2 = 5,000e18  9091e18 not working :( 7750 it is
    //     vm.stopPrank();

    //     // Verify liquidation
    //     assertEq(endingUserHealthFactor, 1e18); // 1 means healthy
    // }

    function testHealthFactorWhenTotalDscMintedIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
        assertEq(collateralValueInUsd, AMOUNT_DSC*2);

        uint256 healthFactor = dsce.getHealthFactor(USER);
        assertEq(healthFactor, type(uint256).max);
    }

    function testHealthFactorWhenCollateralValueIsHigh() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(1e18); // Mint a small amount of DSC
        vm.stopPrank();

        uint256 healthFactor = dsce.getHealthFactor(USER);
        assertGt(healthFactor, 1e18);
    }

    ////////////////////////////////////
    // Additional Tests ////////////////
    ////////////////////////////////////

    function testRevertsIfRedeemMoreThanDeposited() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__CanOnlyLiquidateAmountCollateral.selector);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL * 2); // Attempt to redeem more than deposited
        vm.stopPrank();
    }

    // function testRevertsIfLiquidateLessThanNecessary() public depositedCollateral mintedDsc {
    //     // At this point of the test, $10,000 DSC has been minted with 10 ether collateral
    //     // Manipulate price feed to make USER's position unhealthy
    //     int256 newPrice = 2000e8/2; // Lower price to make position unhealthy
    //     vm.mockCall(ethUsdPriceFeed, abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector), abi.encode(0, newPrice, 0, 0, 0));
    //     // According to the new price, the collateral value is now $5,000
    //     // The total DSC minted is $10,000
    //     // The health factor is 0.5

    //     // ********************GETTING THINGS READY FOR LIQUIDATOR **************************** */

    //     // Deposit collateral and mint DSC

    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL*2); // 20 ether
    //     dsce.depositCollateral(weth, AMOUNT_COLLATERAL*2); // 20 ether
    //     // At this point dsce cannot deposit more collateral because it has already deposited the maximum amount
    //     console.log("Allowance of DSC coming from liquidator1 to DSCEngine", ERC20Mock(weth).allowance(address(this), address(dsce))/1e18);

    //     // Approve the tokens this contract is about to liquidate
    //     uint256 amountDscToMint = AMOUNT_DSC; // 10000e18;
    //     // Approve the amount of DSC Token to the DSCEngine
    //     DecentralizedStableCoin(dsc).approve(address(dsce), amountDscToMint);
    //     console.log("Just before next step");
    //     dsce.mintDsc(amountDscToMint);
    //     // Console the allowances
    //     console.log("Allowance of DSC coming from liquidator to DSCEngine", DecentralizedStableCoin(dsc).allowance(address(this), address(dsce))/1e18);

    //     // ************************************************ */

    //     // Liquidate USER's position
    //     vm.startPrank(address(this));
    //     // Check allowance before liquidation
    //     uint256 allowanceBeforeLiquidation = DecentralizedStableCoin(dsc).allowance(USER, address(dsce));
    //     console.log("Allowance of DSC to DSCEngine before liquidation:", allowanceBeforeLiquidation/1e18);

    //     // Expect revert because the amount to liquidate is less than necessary
    //     // vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
    //     uint256 endingUserHealthFactor = dsce.liquidate(weth, USER, (AMOUNT_DSC/30)); // 10,000e18 / 10 = 1,000e18  
    //     console.log("endingUserHealthFactoryx", endingUserHealthFactor/1e18);
    //     vm.stopPrank();
    // }

    function testDepositCollateralTransferFailed() public {
        // Step 1: Deploy the FailingERC20Mock token
        FailingERC20Mock failingToken = new FailingERC20Mock("FailingToken", "FT", address(this), AMOUNT_COLLATERAL);
        failingToken.mint(USER, AMOUNT_COLLATERAL);

        // Step 2: Add the token to the allowed tokens mapping in the DSCEngine contract
        address[] memory tokenAddresses1 = new address[](1);
        address[] memory priceFeedAddresses1 = new address[](1);
        tokenAddresses1[0] = address(failingToken);
        priceFeedAddresses1[0] = ethUsdPriceFeed; // Use an existing price feed for simplicity
        DSCEngine newDsce = new DSCEngine(tokenAddresses1, priceFeedAddresses1, address(dsc));

        // Step 3: Set the mock token to fail the transfer
        failingToken.setShouldFail(true);

        // Step 4: Test the depositCollateral function
        vm.startPrank(USER);
        failingToken.approve(address(newDsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        newDsce.depositCollateral(address(failingToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testBurnDscTransferFailed() public {
        FailingERC20Mock failingToken = new FailingERC20Mock("FailingToken", "FTK", address(this), AMOUNT_COLLATERAL);
        failingToken.mint(USER, AMOUNT_COLLATERAL);

        // Step 2: Add the token to the allowed tokens mapping in the DSCEngine contract
        address[] memory tokenAddresses2 = new address[](1);
        address[] memory priceFeedAddresses2 = new address[](1);
        tokenAddresses2[0] = address(failingToken);
        priceFeedAddresses2[0] = ethUsdPriceFeed; // Use an existing price feed for simplicity
        DSCEngine newDsce2 = new DSCEngine(tokenAddresses2, priceFeedAddresses2, address(failingToken));

        vm.startPrank(address(dsce)); // Simulate the owner
        // console the owner of dsc
        dsc.transferOwnership(address(newDsce2));
        vm.stopPrank(); 

        vm.startPrank(USER);
        failingToken.approve(address(newDsce2), AMOUNT_COLLATERAL);
        // Approve allowance of dsc to dsce
        DecentralizedStableCoin(dsc).approve(address(newDsce2), 1e18);

        // newDsce2.depositCollateralAndMintDsc(address(failingToken), AMOUNT_COLLATERAL, AMOUNT_DSC); 

        newDsce2.depositCollateral(address(failingToken), AMOUNT_COLLATERAL);
        // newDsce2.mintDsc(1e18); // Mint a small amount of DSC

        failingToken.setShouldFail(true);

        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        newDsce2.burnDsc(1e18); // Attempt to burn DSC
        vm.stopPrank();
    }

    // Function to test that the mintDsc function reverts if the transferFrom function fails
    function testMintDscTransferFailed() public {
        FailingERC20Mock failingToken = new FailingERC20Mock("FailingToken", "FTK", address(this), AMOUNT_COLLATERAL);
        failingToken.mint(USER, AMOUNT_COLLATERAL);

        // Step 2: Add the token to the allowed tokens mapping in the DSCEngine contract
        address[] memory tokenAddresses2 = new address[](1);
        address[] memory priceFeedAddresses2 = new address[](1);
        tokenAddresses2[0] = address(failingToken);
        priceFeedAddresses2[0] = ethUsdPriceFeed; // Use an existing price feed for simplicity
        DSCEngine newDsce2 = new DSCEngine(tokenAddresses2, priceFeedAddresses2, address(failingToken));

        vm.startPrank(address(dsce)); // Simulate the owner
        // console the owner of dsc
        dsc.transferOwnership(address(newDsce2));
        vm.stopPrank(); 

        vm.startPrank(USER);
        failingToken.approve(address(newDsce2), AMOUNT_COLLATERAL);
        // Approve allowance of dsc to dsce
        DecentralizedStableCoin(dsc).approve(address(newDsce2), 1e18);

        // newDsce2.depositCollateralAndMintDsc(address(failingToken), AMOUNT_COLLATERAL, AMOUNT_DSC); 

        newDsce2.depositCollateral(address(failingToken), AMOUNT_COLLATERAL);
        failingToken.setShouldFail(true);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        newDsce2.mintDsc(1e18); // Mint a small amount of DSC
        vm.stopPrank();
    }
}

