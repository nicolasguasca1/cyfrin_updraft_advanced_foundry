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

    ////////////////////////
    // State Variables    //
    ////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;


    mapping (address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping (address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // userToTokenToCollateral
    mapping (address user => uint256 amountDscMinted) private s_DSCMinted; // userToAmountDscMinted

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////////////////
    // Events             //
    ////////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

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
            emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
            bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
            if (!success) {
                revert DSCEngine__TransferFailed();
            }
        }

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    /**
     * @notice follows CEI pattern
     * This function allows a user to withdraw collateral from the system. The user must have enough collateral deposited to withdraw.
     * @param amountDscToMint The amount of DSC to mint
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much ($150 DSC, $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external {}

    ///////////////////////////////////////
    // Private & Internal View Functions //
    ///////////////////////////////////////

    function _getAccountInformation(address user) private view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
        // total DSC minted
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
        return (totalDscMinted, collateralValueInUsd);
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
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // $150 ETH / 100 DSC = 1.5
        // 150 * 50 = 7500 / 100 = 75 -> 75 / 100 < 1 -------Low health factor

        // $1000 ETH equivalent to 100 DSC
        // 1000 * 50 = 50000 / 100 = 500 -> 500 / 100 = 5 -------High health factor
        return (collateralValueInUsd * PRECISION) / totalDscMinted;
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
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValue) {
        // loop through each collateral token, get the amount they have deposited, and map it to the price, to get the USD value
        uint256 totalCollateralValueInUsd = 0;
        for (uint256 i=0; i<s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValue;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION)* amount) / PRECISION;
    }
}