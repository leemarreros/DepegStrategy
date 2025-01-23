// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILBRouter} from "../../src/ILBRouter.sol";
import {MockPriceOracle} from "./MockPriceOracle.sol";

contract MockLBRouter is ILBRouter {
    MockPriceOracle public oracle;

    constructor(address _oracle) {
        oracle = MockPriceOracle(_oracle);
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256, Path memory path, address to, uint256)
        external
        returns (uint256 amountOut)
    {
        address tokenIn = address(path.tokenPath[0]);
        address tokenOut = address(path.tokenPath[path.tokenPath.length - 1]);

        uint256 tokenInPrice = oracle.getAssetPrice(tokenIn);
        uint256 tokenOutPrice = oracle.getAssetPrice(tokenOut);

        amountOut = (amountIn * tokenInPrice) / tokenOutPrice;

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(to, amountOut);

        return amountOut;
    }

    function swapTokensForExactTokens(uint256 amountOut, uint256, Path memory path, address to, uint256)
        external
        returns (uint256 amountIn)
    {
        address tokenIn = address(path.tokenPath[0]);
        address tokenOut = address(path.tokenPath[path.tokenPath.length - 1]);

        uint256 tokenInPrice = oracle.getAssetPrice(tokenIn);
        uint256 tokenOutPrice = oracle.getAssetPrice(tokenOut);

        amountIn = (amountOut * tokenOutPrice) / tokenInPrice;

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(to, amountOut);

        return amountIn;
    }
}
