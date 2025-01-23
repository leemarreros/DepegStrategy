// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IPriceOracleGetter} from "@aave/core-v3/contracts/interfaces/IPriceOracleGetter.sol";

contract MockPriceOracle is IPriceOracleGetter {
    mapping(address => uint256) private prices;

    // Price should be in USD with 8 decimals (Aave standard)
    function setAssetPrice(address asset, uint256 price) external {
        prices[asset] = price;
    }

    function getAssetPrice(address asset) external view override returns (uint256) {
        return prices[asset];
    }

    function BASE_CURRENCY() external pure returns (address) {
        return address(0);
    }

    function BASE_CURRENCY_UNIT() external pure returns (uint256) {
        return 1e8;
    }
}
