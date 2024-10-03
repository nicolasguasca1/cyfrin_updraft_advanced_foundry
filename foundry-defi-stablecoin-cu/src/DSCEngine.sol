// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.20;

import {console} from "lib/forge-std/src/console.sol";

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Patrick Collins
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stable coin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmic Stable
 * 
 * Is is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 * 
 * Our DSC system should always be "overcollateralized" to ensure that the system can always be solvent. At no point, should the value of all collateral <= the $ backed value of all DSC.
 * 
 * 
 * @notice 
 * This contract is the core of the DSC System. It handles all the logic for mintinng and redeeming DSRC, as well as depositing and withdrawing collateral.
 * @notice
 * This contract is VERY loosely based on the MakerDAO DSS (DAI) system
 */

contract DSCEngine is ReentrancyGuard {

    

    ////////////////////////
    // Errors             //
    ////////////////////////

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed(address token);
    error DSCEngine__TransferFailed();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__CanOnlyLiquidateAmountCollateral();

    ////////////////////////
    // State Variables    //
    ////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e8;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // This will be a 10% BONUS

    mapping (address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping (address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // userToTokenToCollateral
    mapping (address user => uint256 amountDscMinted) private s_DSCMinted; // userToAmountDscMinted

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////////////////
    // Events             //
    ////////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address token, uint256 amount);

    ////////////////////////
    // Modifiers          //
    ////////////////////////

    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    // Modifier to allow only certain token addresses from an allowance mapping. Use error functions to provide feedback to the user instead of text revert messages
    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed(token);
        }
        _;
    }

    ////////////////////////
    // Functions          //
    ////////////////////////

    constructor(
        address[] memory tokenAddresses, 
        address[] memory priceFeedsAddress,
        address dscAddress
        ) {
            // USD Price Feed
            if (tokenAddresses.length != priceFeedsAddress.length) {
                revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
            }
            // These feeds will be the USD pairs
            // For example ETH / USD or MKR / USD 
            for (uint256 i=0; i<tokenAddresses.length; i++) {
                s_priceFeeds[tokenAddresses[i]] = priceFeedsAddress[i];
                s_collateralTokens.push(tokenAddresses[i]);
            } 
            i_dsc = DecentralizedStableCoin(dscAddress);
        }

    ////////////////////////
    // External Functions //
    ////////////////////////

    /**
     * @notice follows CEI pattern
     * This function allows a user to deposit collateral into the system and mint DSC. The user must have approved the DSC contract to spend the collateral.
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of DSC to mint
     * @notice This function will deposit the collateral first, then mint the DSC
     */
    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI pattern
     * This function allows a user to deposit collateral into the system. The user must have approved the DSC contract to spend the collateral.
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(
        address tokenCollateralAddress, 
        uint256 amountCollateral
        ) 
        public 
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress) 
        nonReentrant 
        {
            s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
            console.log("sender in depcollateral is", msg.sender);
            console.log("colateral depositado: ",s_collateralDeposited[msg.sender][tokenCollateralAddress]);
            emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
            bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
            if (!success) {
                revert DSCEngine__TransferFailed();
            }
            console.log("balance of this contract: ", IERC20(tokenCollateralAddress).balanceOf(address(this)));
        }

    /**
     * @notice follows CEI pattern
     * This function allows a user to redeem collateral from the system and burn DSC. The user must have enough DSC to burn.
     * @param tokenCollateralAddress The address of the token to redeem as collateral
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * @notice This function will burn the DSC, then redeem the collateral in one transaction 
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks health factor
    }

    // In order to redeem collateral:
    // 1. Health factor must be over 1 AFTER collateral pulled
    // CEI; Checks, Effects, Interaction
    function redeemCollateral(address tokenCollateralAddress, uint amountCollateral) public
    moreThanZero(amountCollateral)
    nonReentrant {
        _redeemCollateral(msg.sender,msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender); 
    }

    // $100 ETH -> 20 DSC

    /**
     * @notice follows CEI pattern
     * This function allows a user to withdraw collateral from the system. The user must have enough collateral deposited to withdraw.
     * @param amountDscToMint The amount of DSC to mint
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much ($150 DSC, $100 ETH)
                console.log("user during mintDsc", _healthFactor(msg.sender));

        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // Not necessary, but good to have
    }

    // If we do start nearing undercollateralization, we need someone to liquidate positions

    // $100 ETH backing $50 DSC
    // $20 ETH backing $50 DSC <- DSC isn't worth $50 anymore

    // $75 backing $50 DSC
    // liquidator take $75 backing and burns off the $50 DSC

    // If someone is almost undercollateralized, we will pay you to liquidate them!
    /**
     * @notice
     * This function allows a liquidator to liquidate a user's position if they are undercollateralized
     * @param collateral The erc20 collateral address to liquidate from the user
     * @param user The address of the user who has broken the health factor. Their _healthFactor should be below MIN_HELATH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health factor
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users funds.
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized for this to work.
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we woldn't be able to incentive the liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 debtToCover) 
    external 
    moreThanZero(debtToCover)
    nonReentrant {
        // 1. Need to check health factor of user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // We want to burn their DSC "debt"
        // And take their collateral
        // Bad User: $140 ETH, $100 DSC
        // debtToCover = $100 DSC
        // $100 of DSC == ??? ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        console.log("tokenAmountFromDebtCovered", tokenAmountFromDebtCovered); // 5e18 -> 5 ETH
        // And give them a 10% bonus
        // So we're giving the liquidator $110 of WETH for 100 DSC
        //We should implement a feature to liquidate in the event the protocol is insolvent 
        // And sweep extra amounts into a treasury

        // 0.05 * 0.1 = 0.005. Getting 0.055
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        console.log("bonusCollateral", bonusCollateral);
        uint256 totalCollateralToredeem = tokenAmountFromDebtCovered + bonusCollateral;
        console.log("totalCollateralToredeem", totalCollateralToredeem); // 5.5e18
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToredeem);
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        console.log("endingUserHealthFactor", endingUserHealthFactor);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
    }

    function getHealthFactor() external {}

    ///////////////////////////////////////
    // Private & Internal View Functions //
    ///////////////////////////////////////

    /**
     * @dev Low-level internal function, do not call unless the function calling it is checking for health factors being broken 
     * @notice
     * This function allows a user to redeem collateral from the system. The user must have enough DSC to burn.
     * @param amountDscToBurn The amount of DSC to burn
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        console.log("Allowance of DSC to DSCEngine from burn func", DecentralizedStableCoin(i_dsc).allowance(dscFrom, address(this)));
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this),amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    } 

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral) internal {
        // Handle the case if amountCollateral > s_collateralDeposited[from][tokenCollateralAddress]
        // log the amount of collateral deposited
        console.log("amountCollateral on loser account", s_collateralDeposited[from][tokenCollateralAddress]); // 10e18
        if (amountCollateral > s_collateralDeposited[from][tokenCollateralAddress]) {
            revert DSCEngine__CanOnlyLiquidateAmountCollateral();
        }
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        console.log("amountCollateral on loser account after", s_collateralDeposited[from][tokenCollateralAddress]); // 4.5e18
        emit CollateralRedeemed(from,to,tokenCollateralAddress,amountCollateral);
        // _calculateHealthFactorAfter()
        // log the amount of collateral to be sent to the winner
        // Check allowance after approval
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        s_collateralDeposited[to][tokenCollateralAddress] += amountCollateral;

        
        console.log("amountCollateral on winner account", s_collateralDeposited[to][tokenCollateralAddress]); // 5.5e18
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }


    function _getAccountInformation(address user) private view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
        // total DSC minted
        // CONSOLE USER
        console.log("userxx", user);
        totalDscMinted = s_DSCMinted[user];
        console.log("totalDscMintedXX", totalDscMinted);
        collateralValueInUsd = getAccountCollateralValue(user);
        console.log("collateralValueInUsdXX", collateralValueInUsd);
        return (totalDscMinted, collateralValueInUsd);
        // BUG IS HERE!!!!!!!!!!
    }

    /**º
     * @notice 
     * Returns how close to liquidation a user is to the system
     * If a user goes below 1, they are liquidated
     * @param user The address of the user to check the health factor of
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        console.log("User is", user);
        console.log("totalDscMinted", totalDscMinted);
        console.log("collateralValueInUsd", collateralValueInUsd);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // $150 ETH / 100 DSC = 1.5
        // 150 * 50 = 7500 / 100 = 75 -> 75 / 100 < 1 -------Low health factor

        // $1000 ETH equivalent to 100 DSC
        // 1000 * 50 = 50000 / 100 = 500 -> 500 / 100 = 5 -------High health factor
        // console.log("healthyy", (collateralAdjustedForThreshold * PRECISION/ totalDscMinted));
        if (totalDscMinted == 0) {
            return type(uint256).max;  // Maximum value for uint256, meaning no risk
        }
        console.log("healthFactor is", (collateralAdjustedForThreshold * PRECISION / totalDscMinted));
        return (collateralAdjustedForThreshold * PRECISION / totalDscMinted);
    }
    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. Check health factor (do they have enough collateral?)
        // 2. If not, revert
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(healthFactor);
        }
    }

    ///////////////////////////////////////
    // Public & External View Functions //
    ///////////////////////////////////////

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int price,,,) = priceFeed.latestRoundData();
        return (uint256(price)* amount) / ADDITIONAL_FEED_PRECISION;
    }

    /**
     * @notice
     * This function allows a user to get the amount of tokens they can get for a certain amount of USD
     * @param token The address of the token to get the amount of
     * @param usdAmount The amount of USD to get the token amount for
     */
    function getTokenAmountFromUsd(address token, uint256 usdAmount) public view returns (uint256) {
        // price of ETH (token)
        // $/ETH ETH?
        // $2000 / ETH. $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int price,,,) = priceFeed.latestRoundData();
        // log the price
        console.log("price from getTokenAmountFromUsd", price);
        return ((usdAmount) / uint256(price)) * ADDITIONAL_FEED_PRECISION;
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValue) {
        // loop through each collatera
        //BUG IS HERE!!!!!!!!!!l token, get the amount they have deposited, and map it to the price, to get the USD value
        uint256 totalCollateralValueInUsd = 0;
        for (uint256 i=0; i<s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];

            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getAccountInformation(address user) external view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }
}