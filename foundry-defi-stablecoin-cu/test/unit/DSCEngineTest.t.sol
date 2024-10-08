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
import { MockV3Aggregator } from "../mocks/MockV3Aggregator.sol";


contract DSCEngineTest is Test {
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if
        // redeemFrom != redeemedTo, then it was liquidated


    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig public config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    address public user = address(1);
    uint256 public constant AMOUNT_COLLATERAL = 10 ether; // In wei it would be 10e18 
    uint256 public constant AMOUNT_DSC = 10000e18;
    uint256 public amountToMint = 100 ether; // $100. Simply expressed as Ether for simplicity
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

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
    // Price Tests ////////
    ///////////////////////


    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100;
        uint256 usdAmountInWei = usdAmount * 1e18;
        // $2,000 / ETH, $100
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmountInWei);
        assertEq(expectedWeth, actualWeth);
    }

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/ETH = 30,000e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    ////////////////////////////////////
    // depositCollateral Tests /////////
    ////////////////////////////////////

    function testRevertsIfTransferFromFails() public {
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

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testCanDepositedCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedDepositedAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, 0);
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
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

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ///////////////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        console.log("Price of ETH", price);
        amountToMint = (AMOUNT_COLLATERAL * (uint256(price))) 
        / dsce.getAdditionalFeedPrecision();
        // )) / dsce.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, AMOUNT_DSC);
    }

    ////////////////////////////////////
    // mintDsc Tests ///////////////////
    ////////////////////////////////////

    // Function to test that the mintDsc function reverts if the transferFrom function fails
    function testRevertsIfMintFails() public {
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

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (AMOUNT_DSC * (uint256(price) / dsce.getAdditionalFeedPrecision()));

        vm.startPrank(USER);
        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountToMint, dsce.getAccountCollateralValue(USER)); // INSTEAD OF GETUSDVALUE!
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(amountToMint);
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
    // burnDsc Tests ///////////////////
    ////////////////////////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(user);
        vm.expectRevert();
        dsce.burnDsc(1);
    }

    function testCanBurnDsc() public depositedCollateral mintedDsc {
        vm.startPrank(USER);
        uint256 amountDscToMint = AMOUNT_DSC; // 10000e18 -> 10,000 DSC
        dsce.burnDsc(amountDscToMint);
        (uint256 totalDscMinted, ) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
        vm.stopPrank();
    }

    ////////////////////////////////////
    // redeemCollateral Tests /////////
    ////////////////////////////////////

    function testRevertsIfTransferFails() public {
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

    function testRevertsIfRedeemAmountIsZero() public {
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

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        // expect to emit CollateralRedeemed event with correct args
        vm.expectEmit(true, true, true, true, address(dsce));
        emit CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ///////////////////////////////////
    // redeemCollateralForDsc Tests //
    //////////////////////////////////

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 1 ether; //Starting to use this convention instead of 1e18
        uint256 healthFactor = dsce.getHealthFactor(USER);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Rememeber, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dsce.getHealthFactor(USER);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        console.log("userHealthFactoryx", userHealthFactor);
        assert(userHealthFactor == 0.009 ether);
    }

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
    // liquidation Tests ///////////////
    ////////////////////////////////////

    function testMustImproveHealthFactorOnLiquidation() public depositedCollateral mintedDsc {
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
        dsce.liquidate(weth, USER, (AMOUNT_DSC/2)); // 10,000e18 / 2 = 5,000e18  
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateral mintedDsc {
        vm.startPrank(address(this));
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, AMOUNT_DSC); // 10,000e18
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dsce.getHealthFactor(USER);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.liquidate(weth, USER, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, amountToMint)
            + (dsce.getTokenAmountFromUsd(weth, amountToMint) / dsce.getLiquidationBonus());
        uint256 hardCodedExpected = 6111_111_111_050_000_000; // 6111111111050000000
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = dsce.getTokenAmountFromUsd(weth, amountToMint)
            + (dsce.getTokenAmountFromUsd(weth, amountToMint) / dsce.getLiquidationBonus());

        uint256 usdAmountLiquidated = dsce.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = dsce.getUsdValue(weth, AMOUNT_COLLATERAL) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 hardCodedExpectedValue = 70_000_000_001_100_000_000; // 70000000001100000000
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = dsce.getAccountInformation(liquidator);
        assertEq(liquidatorDscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = dsce.getAccountInformation(user);
        assertEq(userDscMinted, 0);
    }

    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = dsce.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = dsce.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = dsce.getMinHealthFactor();
        assertEq(minHealthFactor, 1 ether);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = dsce.getLiquidationThreshold();
        assertEq(liquidationThreshold, 50);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = dsce.getAccountInformation(USER);
        uint256 expectedCollateralValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralBalance = dsce.getCollateralBalanceOfUser(USER, weth);
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralValue = dsce.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public view {
        address dscAddress = dsce.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public view {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dsce.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
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
        console.log("Was able to burn");
        vm.expectRevert();
        // vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        dsce.burnDsc(2e18); // Attempt to burn more than minted
        // vm.stopPrank();
    }    

}

