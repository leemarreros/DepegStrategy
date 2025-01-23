// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Test} from "forge-std/Test.sol";
import {DepegStrategy} from "../src/DepegStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockToken} from "../test/mocks/MockToken.sol";
import {MockPriceOracle} from "../test/mocks/MockPriceOracle.sol";
import {MockPool} from "../test/mocks/MockPool.sol";
import {MockLBRouter} from "../test/mocks/MockLBRouter.sol";
import {MockPoolAddressesProvider} from "../test/mocks/MockPoolAddressesProvider.sol";

contract DepegStrategyTest is Test {
    MockToken public collateralToken;
    MockToken public debtToken;

    MockPriceOracle public oracle;
    MockPool public pool;
    MockLBRouter public router;
    MockPoolAddressesProvider public addressesProvider;

    DepegStrategy public implementation;
    DepegStrategy public strategy;

    uint256 constant INITIAL_LIQUIDITY = 1_000_000e6;
    uint256 constant USER_LIQUIDITY = 1_000e6;
    uint256 constant TARGET_LEVERAGE_RATIO = 10;

    bytes32 constant TRUSTED_ROLE = keccak256("TRUSTED_ROLE");
    bytes32 constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    function _deployDependencies() public {
        collateralToken = new MockToken("USDC", "USDC", 6);
        debtToken = new MockToken("USDT", "USDT", 6);

        oracle = new MockPriceOracle();
        addressesProvider = new MockPoolAddressesProvider(address(oracle));

        pool = new MockPool(address(oracle), address(collateralToken), address(debtToken));
        router = new MockLBRouter(address(oracle));

        collateralToken.mint(address(router), INITIAL_LIQUIDITY);
        debtToken.mint(address(router), INITIAL_LIQUIDITY);

        debtToken.mint(address(pool), INITIAL_LIQUIDITY);
    }

    function _deployingDepegStrategy() public {
        implementation = new DepegStrategy();
        bytes memory initData = abi.encodeWithSelector(
            DepegStrategy.initialize.selector,
            address(this), // trusted
            address(this), // executor
            address(pool),
            address(router),
            address(addressesProvider),
            TARGET_LEVERAGE_RATIO
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        strategy = DepegStrategy(address(proxy));
        strategy.grantRole(TRUSTED_ROLE, address(this));
        strategy.grantRole(EXECUTOR_ROLE, address(this));
    }

    function _setUpShortStrategy() public {
        //SHORT strategy:       debt token (USDT): 1.0 -> 0.9
        //                collateral token (USDC): 1.0 -> 1.0
        _deployDependencies();
        _deployingDepegStrategy();

        oracle.setAssetPrice(address(collateralToken), 1e8);
        oracle.setAssetPrice(address(debtToken), 1e8);

        collateralToken.mint(address(strategy), USER_LIQUIDITY);
    }

    function testShortStrategy() public {
        _setUpShortStrategy();

        uint256 initialCollateral = collateralToken.balanceOf(address(strategy));

        strategy.enterLeverage(collateralToken, debtToken, USER_LIQUIDITY);

        oracle.setAssetPrice(address(debtToken), 0.9e8);

        strategy.unwindLeverage(collateralToken, debtToken);

        uint256 finalCollateral = collateralToken.balanceOf(address(strategy));

        assertTrue(finalCollateral > initialCollateral);
    }

    function _setUpLongStrategy() public {
        //LONG strategy: collateral token (USDC): 0.9 -> 1.0
        //                     debt token (USDT): 1.0 -> 1.0

        _deployDependencies();
        _deployingDepegStrategy();

        oracle.setAssetPrice(address(collateralToken), 0.9e8);
        oracle.setAssetPrice(address(debtToken), 1e8);

        collateralToken.mint(address(strategy), USER_LIQUIDITY);
    }

    function testLongStrategy() public {
        _setUpLongStrategy();

        uint256 initialCollateral = collateralToken.balanceOf(address(strategy));

        strategy.enterLeverage(collateralToken, debtToken, USER_LIQUIDITY);

        oracle.setAssetPrice(address(collateralToken), 1e8);

        strategy.unwindLeverage(collateralToken, debtToken);

        uint256 finalCollateral = collateralToken.balanceOf(address(strategy));

        assertTrue(finalCollateral > initialCollateral);
    }
}
