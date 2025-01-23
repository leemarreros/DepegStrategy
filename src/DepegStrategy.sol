// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPriceOracleGetter} from "@aave/core-v3/contracts/interfaces/IPriceOracleGetter.sol";
import {IFlashLoanSimpleReceiver} from "@aave/core-v3/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import {DataTypes} from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";
import {ILBRouter} from "./ILBRouter.sol";

/// @custom:security-contact lee.marreros@pucp.pe
contract DepegStrategy is Initializable, AccessControlUpgradeable, UUPSUpgradeable, IFlashLoanSimpleReceiver {
    struct LeverageParams {
        uint256 totalCollateralBase;
        uint256 totalDebtBase;
        uint256 availableBorrowsBase;
        uint256 currentLiquidationThreshold;
        uint256 balanceDebtBefore;
        uint256 actualDebtBorrowed;
        uint256 healthFactor;
    }

    bytes32 public constant TRUSTED_ROLE = keccak256("TRUSTED_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    uint256 private constant STABLE_BIN_STEP = 1;
    uint8 public constant STABLECOIN_EMODE_ID = 1;
    uint256 public constant SAFE_HEALTH_FACTOR = 10500; // 105%

    uint256 public constant MAX_LIMIT_ITERATION = 20;
    uint16 public constant REFERRAL_CODE = 0;
    uint16 public constant VARIABLE_RATE = 2;

    IPriceOracleGetter priceOracle;
    ILBRouter lbRouter;
    IPool pool;

    address poolAddressProvider;

    uint256 public targetLeverageRatio; // 3300 = 33%

    event StrategyEntered(
        address indexed collateralToken, address indexed debtToken, uint256 amount, uint256 timestamp
    );

    event StrategyUnwound(
        address indexed collateralToken, address indexed debtToken, uint256 profitAmount, uint256 timestamp
    );

    error Unauthorized();
    error ApprovalFailed(address token, address spender);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _trustedAddress,
        address _executorAddress,
        address _poolAddress,
        address _lbRouterAddress,
        address _poolAddressesProviderAddress,
        uint256 _targetLeverageRatio
    ) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _trustedAddress);
        _grantRole(TRUSTED_ROLE, _trustedAddress);
        _grantRole(EXECUTOR_ROLE, _executorAddress);

        pool = IPool(_poolAddress);

        lbRouter = ILBRouter(_lbRouterAddress);

        targetLeverageRatio = _targetLeverageRatio;

        pool.setUserEMode(STABLECOIN_EMODE_ID);

        poolAddressProvider = _poolAddressesProviderAddress;
        address oracleAddress = IPoolAddressesProvider(poolAddressProvider).getPriceOracle();
        priceOracle = IPriceOracleGetter(oracleAddress);
    }

    /**
     * @dev The function supplies collateral to the Aave pool, borrows debt tokens, swaps them for additional collateral,
     *      and reinvests the collateral until the target leverage ratio or safe health factor is reached.
     * @param collateralToken The ERC20 token used as collateral in the Aave pool.
     * @param debtToken The ERC20 token to be borrowed during the leveraging process.
     * @param supplyAmount The initial amount of collateral tokens to supply to the Aave pool.
     */
    function enterLeverage(IERC20 collateralToken, IERC20 debtToken, uint256 supplyAmount)
        public
        onlyRole(EXECUTOR_ROLE)
    {
        uint256 collateralTokenPrice = priceOracle.getAssetPrice(address(collateralToken));
        uint256 debtTokenPrice = priceOracle.getAssetPrice(address(debtToken));

        uint256 initialCollateral = supplyAmount;

        LeverageParams memory params;

        for (uint256 i = 0; i < MAX_LIMIT_ITERATION; i++) {
            if (!collateralToken.approve(address(pool), supplyAmount)) {
                revert ApprovalFailed(address(collateralToken), address(pool));
            }
            pool.supply(address(collateralToken), supplyAmount, address(this), REFERRAL_CODE);

            (
                params.totalCollateralBase,
                params.totalDebtBase,
                params.availableBorrowsBase,
                params.currentLiquidationThreshold,
                ,
                params.healthFactor
            ) = pool.getUserAccountData(address(this));

            uint256 newTotalDebtBase = params.totalDebtBase + params.availableBorrowsBase;
            uint256 newHealthFactor = (
                (params.totalCollateralBase + params.availableBorrowsBase) * params.currentLiquidationThreshold
            ) / newTotalDebtBase;
            if (newHealthFactor < SAFE_HEALTH_FACTOR) break;

            uint256 newLeverageRatio = _denormalizeUsdToToken(
                params.totalCollateralBase + params.availableBorrowsBase, collateralTokenPrice
            ) / initialCollateral;
            if (newLeverageRatio > targetLeverageRatio) break;

            uint256 balanceDebtBefore = debtToken.balanceOf(address(this));
            pool.borrow(
                address(debtToken),
                _denormalizeUsdToToken(params.availableBorrowsBase, debtTokenPrice),
                VARIABLE_RATE,
                REFERRAL_CODE,
                address(this)
            );
            uint256 actualDebtBorrowed = debtToken.balanceOf(address(this)) - balanceDebtBefore;

            (params.totalCollateralBase, params.totalDebtBase,,,,) = pool.getUserAccountData(address(this));

            supplyAmount = _swapExactTokenInByTokenOut(debtToken, collateralToken, actualDebtBorrowed);
        }

        emit StrategyEntered(address(collateralToken), address(debtToken), supplyAmount, block.timestamp);
    }

    /**
     * @dev This function initiates a flash loan to cover the debt from aave, repays it, retrieves the locked collateral,
     *      and handles the repayment of the flash loan. The function fully unwinds the user's leverage.
     * @param collateralToken The ERC20 token used as collateral in the Aave pool.
     * @param debtToken The ERC20 token representing the debt to be repaid during the unwinding process.
     */
    function unwindLeverage(IERC20 collateralToken, IERC20 debtToken) public onlyRole(EXECUTOR_ROLE) {
        DataTypes.ReserveData memory reserveData = pool.getReserveData(address(debtToken));
        address variableDebtTokenAddress = reserveData.variableDebtTokenAddress;
        uint256 debtAmount = IERC20(variableDebtTokenAddress).balanceOf(address(this));

        bytes memory params = abi.encode(address(collateralToken));
        pool.flashLoanSimple(address(this), address(debtToken), debtAmount, params, REFERRAL_CODE);

        emit StrategyUnwound(address(collateralToken), address(debtToken), debtAmount, block.timestamp);
    }

    function executeOperation(
        address debtAssetAddress,
        uint256 debtTokenAmount,
        uint256 premium,
        address,
        bytes calldata params
    ) external override returns (bool) {
        if (msg.sender != address(pool)) revert Unauthorized();

        if (!IERC20(debtAssetAddress).approve(address(pool), debtTokenAmount)) {
            revert ApprovalFailed(address(debtAssetAddress), address(pool));
        }
        pool.repay(debtAssetAddress, debtTokenAmount, VARIABLE_RATE, address(this));
        address collateralTokenAddress = abi.decode(params, (address));
        pool.withdraw(collateralTokenAddress, type(uint256).max, address(this));

        uint256 amountToRepayFlashLoan = debtTokenAmount + premium;
        _swapTokenInByExactTokenOut(IERC20(collateralTokenAddress), IERC20(debtAssetAddress), amountToRepayFlashLoan);

        IERC20(debtAssetAddress).approve(address(pool), amountToRepayFlashLoan);

        return true;
    }

    function withdrawFunds(IERC20 collateralToken, IERC20 debtToken) public onlyRole(TRUSTED_ROLE) {
        pool.withdraw(address(collateralToken), type(uint256).max, address(this));
        pool.withdraw(address(debtToken), type(uint256).max, address(this));
    }

    function updateTargetLeverageRatio(uint256 _targetLeverageRatio) public onlyRole(TRUSTED_ROLE) {
        targetLeverageRatio = _targetLeverageRatio;
    }

    ///////////////////////////////////////////////////////////////////
    /////////////////////    HELPER METHODS    ////////////////////////
    ///////////////////////////////////////////////////////////////////
    function ADDRESSES_PROVIDER() public view override returns (IPoolAddressesProvider) {
        return IPoolAddressesProvider(poolAddressProvider);
    }

    function POOL() public view override returns (IPool) {
        return pool;
    }

    function _buildPath(IERC20 tokenIn, IERC20 tokenOut) private pure returns (ILBRouter.Path memory path) {
        path.pairBinSteps = new uint256[](1);
        path.pairBinSteps[0] = STABLE_BIN_STEP;

        path.versions = new ILBRouter.Version[](1);
        path.versions[0] = ILBRouter.Version.V2_2;

        path.tokenPath = new IERC20[](2);
        path.tokenPath[0] = tokenIn;
        path.tokenPath[1] = tokenOut;
    }

    function _denormalizeUsdToToken(uint256 usdAmount, uint256 tokenPrice)
        internal
        pure
        returns (uint256 tokenAmount)
    {
        tokenAmount = (usdAmount * 1e6) / tokenPrice;
    }

    function _swapExactTokenInByTokenOut(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        if (!tokenIn.approve(address(lbRouter), amountIn)) revert ApprovalFailed(address(tokenIn), address(lbRouter));

        ILBRouter.Path memory path = _buildPath(tokenIn, tokenOut);

        uint256 amountOutMin = (amountIn * 99) / 100;

        uint256 fiveMinutes = 5 * 60;
        amountOut = lbRouter.swapExactTokensForTokens(
            amountIn, amountOutMin, path, address(this), block.timestamp + fiveMinutes
        );
    }

    function _swapTokenInByExactTokenOut(IERC20 tokenIn, IERC20 tokenOut, uint256 amountOut)
        internal
        returns (uint256 amountIn)
    {
        uint256 amountInMax = (amountOut * 101) / 100;
        if (!tokenIn.approve(address(lbRouter), amountInMax)) {
            revert ApprovalFailed(address(tokenIn), address(lbRouter));
        }

        ILBRouter.Path memory path = _buildPath(tokenIn, tokenOut);

        uint256 fiveMinutes = 5 * 60;
        amountIn = lbRouter.swapTokensForExactTokens(
            amountOut, amountInMax, path, address(this), block.timestamp + fiveMinutes
        );
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(TRUSTED_ROLE) {}
}
