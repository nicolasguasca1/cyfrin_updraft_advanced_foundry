// // SPDX-License-Identifier: MIT
// // Have our invariant aka properties

// // What are the invariats?

// // 1. The total supply of DSC token should always be less than the total value of collateral
// // 2. Getter view functions should never revert <- evergreen invariant

// // Future work. The total supply of DSC token is always equal to the sum of the balances of all accounts.

// pragma solidity ^0.8.20;

// import {Test, console} from "lib/forge-std/src/Test.sol";
// import {StdInvariant} from "lib/forge-std/src/StdInvariant.sol";
// import {DeployDSC} from "script/DeployDSC.s.sol";
// import {DSCEngine} from "src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "script/HelperConfig.s.sol";

// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


// contract OpenInvariantsTest is StdInvariant, Test {
//     // Set up the state of the contract before each test
//     DeployDSC deployer;
//     DSCEngine dsce;
//     DecentralizedStableCoin dsc;
//     HelperConfig config;
//     address weth;
//     address wbtc;

//     function setUp() public {
//         deployer = new DeployDSC();
//         (dsc, dsce, config) = deployer.run();
//         // targetContract(address(dsce));
//         (,,weth,wbtc,) = config.activeNetworkConfig();
//         console.log("DSCEngine Address: ", address(dsce));
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
//         // get the value of all the collateral in the protocol
//         // compare it to all the debt (dsc)
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

//         uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
//         uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

//         console.log("WETH Value: ", wethValue);
//         console.log("WBTC Value: ", wbtcValue);
//         console.log("Total Supply: ", totalSupply);

//         assert (wethValue + wbtcValue >= totalSupply);
//     }

//     // function invariant_getterFunctionsShouldNotRevert() public view {
//     //     // Check if the getter functions revert
//     //     dsce.getUsdValue(weth, 0);
//     //     dsce.getUsdValue(wbtc, 0);
//     // }
// }