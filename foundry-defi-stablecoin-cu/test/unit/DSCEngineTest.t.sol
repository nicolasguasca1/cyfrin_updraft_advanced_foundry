// SPDX-License-Identifier: MIT 

pragma solidity 0.8.20;

import {console} from "lib/forge-std/src/console.sol";


import {Test} from "lib/forge-std/src/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

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
        console.log("Allowance of WETH to DSCEngine", ERC20Mock(weth).allowance(USER, address(dsce)));
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
        console.log("Allowance of DSC to DSCEngine", DecentralizedStableCoin(dsc).allowance(USER, address(dsce)));

        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        console.log("totalDscMinted", totalDscMinted);
        console.log("collateralValueInUsd", collateralValueInUsd);

        // 10.000000000000000000 eth as colateral
        // 100000000000.00000000000000000000000000
        uint256 expectedTotalDscMinted = 0;
        console.log("expectedTotalDscMinted", expectedTotalDscMinted);
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        console.log("expectedDepositAmount", expectedDepositAmount);
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
        assertEq(collateralValueInUsd, 0);
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

    ////////////////////////////////////
    // liquidation Tests ///////////////
    ////////////////////////////////////

    function testRevertsIfLiquidateHealthyPosition() public depositedCollateral mintedDsc {
        vm.startPrank(address(this));
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, AMOUNT_DSC); // 10,000e18
        vm.stopPrank();
    }

    function testCanLiquidateUnhealthyPosition() public depositedCollateral mintedDsc {
        // At this point of the test, $10,000 DSC has been minted with 10 ether collateral
        // Manipulate price feed to make USER's position unhealthy
        int256 newPrice = 2000e8/2; // Lower price to make position unhealthy
        vm.mockCall(ethUsdPriceFeed, abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector), abi.encode(0, newPrice, 0, 0, 0));
        // According to the new price, the collateral value is now $5,000
        // The total DSC minted is $10,000
        // The health factor is 0.5

        // ********************GETTING THINGS READY FOR LIQUIDATOR **************************** */

        // Deposit collateral and mint DSC

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL*2); // 10 ether
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL*2);
        // At this point dscr cannot deposit more collateral because it has already deposited the maximum amount
        console.log("Allowance of DSC coming from liquidator1 to DSCEngine", ERC20Mock(weth).allowance(address(this), address(dsce)));

        // Approve the tokens this contract is about to liquidate
        uint256 amountDscToMint = AMOUNT_DSC; // 10000e18;
        // Approve the amount of DSC Token to the DSCEngine
        DecentralizedStableCoin(dsc).approve(address(dsce), amountDscToMint);
        console.log("Just before next step");
        dsce.mintDsc(amountDscToMint);
        // Console the allowances
        console.log("Allowance of DSC coming from liquidator to DSCEngine", DecentralizedStableCoin(dsc).allowance(address(this), address(dsce)));

        // ************************************************ */

        // Liquidate USER's position
        vm.startPrank(address(this));
        // Check allowance before liquidation
        uint256 allowanceBeforeLiquidation = DecentralizedStableCoin(dsc).allowance(USER, address(dsce));
        console.log("Allowance of DSC to DSCEngine before liquidation:", allowanceBeforeLiquidation);

        dsce.liquidate(weth, USER, AMOUNT_DSC/2); // 10,000e18 / 2 = 5,000e18  
        vm.stopPrank();

        // Verify liquidation
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
        assertEq(collateralValueInUsd, 0);
    }
}

