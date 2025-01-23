// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {console2} from "forge-std/console2.sol";
import {MockPriceOracle} from "./MockPriceOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinimalPool} from "./IMinimalPool.sol";
import {DataTypes} from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";
import {IFlashLoanSimpleReceiver} from "@aave/core-v3/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import {MockToken} from "./MockToken.sol";

interface IERC20Extended is IERC20 {
    function decimals() external view returns (uint8);
}

contract MockPool is IMinimalPool {
    MockPriceOracle public oracle;
    MockToken public variableDebtToken;

    uint256 public constant FLASH_LOAN_PREMIUM = 9;

    mapping(address => uint256) public userCollateral;
    mapping(address => uint256) public userDebt;

    address public immutable collateralTokenAddress;
    address public immutable debtTokenAddress;

    constructor(address _oracle, address _collateralTokenAddress, address _debtTokenAddress) {
        oracle = MockPriceOracle(_oracle);
        collateralTokenAddress = _collateralTokenAddress;
        debtTokenAddress = _debtTokenAddress;

        uint8 underlyingDecimals = IERC20Extended(_debtTokenAddress).decimals();
        variableDebtToken = new MockToken("Variable Debt Token", "VDT", underlyingDecimals);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        userCollateral[onBehalfOf] += amount;
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        if (amount == type(uint256).max) {
            require(userDebt[msg.sender] == 0, "User has debt");
            amount = userCollateral[msg.sender];
            userCollateral[msg.sender] = 0;
        } else {
            require(userCollateral[msg.sender] >= amount, "Insufficient balance");
            userCollateral[msg.sender] -= amount;
        }
        IERC20(asset).transfer(to, amount);
        return amount;
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external override {
        userDebt[onBehalfOf] += amount;
        IERC20(asset).transfer(msg.sender, amount);
        variableDebtToken.mint(onBehalfOf, amount);
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external override returns (uint256) {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        userDebt[onBehalfOf] -= amount;
        variableDebtToken.burn(onBehalfOf, amount);
        return amount;
    }

    function getUserAccountData(address user)
        external
        view
        override
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        // Convert token amounts to USD base (8 decimals)
        totalCollateralBase = userCollateral[user] * oracle.getAssetPrice(collateralTokenAddress) / 1e6;
        totalDebtBase = userDebt[user] * oracle.getAssetPrice(debtTokenAddress) / 1e6;

        ltv = 9300;
        currentLiquidationThreshold = 8000;
        availableBorrowsBase = (totalCollateralBase * ltv / 10000) - totalDebtBase;

        healthFactor = totalDebtBase == 0
            ? type(uint256).max
            : (totalCollateralBase * currentLiquidationThreshold / 10000) / totalDebtBase;
    }

    function getReserveData(address) external view returns (DataTypes.ReserveData memory) {
        DataTypes.ReserveData memory reserveData;
        reserveData.variableDebtTokenAddress = address(variableDebtToken);
        return reserveData;
    }

    function flashLoanSimple(address receiverAddress, address asset, uint256 amount, bytes calldata params, uint16)
        external
    {
        // 1. Calculate premium
        uint256 premium = (amount * FLASH_LOAN_PREMIUM) / 10000;
        uint256 amountPlusPremium = amount + premium;

        // 2. Transfer requested amount to receiver
        IERC20(asset).transfer(receiverAddress, amount);

        // 3. Execute operation on receiver
        require(
            IFlashLoanSimpleReceiver(receiverAddress).executeOperation(asset, amount, premium, msg.sender, params),
            "Flash loan failed"
        );

        // 4. Get amount + premium back
        require(
            IERC20(asset).transferFrom(receiverAddress, address(this), amountPlusPremium), "Flash loan repayment failed"
        );
    }

    function setUserEMode(uint8 categoryId) external {}
}
