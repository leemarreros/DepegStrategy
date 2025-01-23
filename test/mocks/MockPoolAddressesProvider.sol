// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";

contract MockPoolAddressesProvider is IPoolAddressesProvider {
    address public oracle;

    constructor(address _oracle) {
        oracle = _oracle;
    }

    function getPriceOracle() external view returns (address) {
        return oracle;
    }

    function getMarketId() external view returns (string memory) {}
    function setMarketId(string calldata newMarketId) external {}
    function getAddress(bytes32 id) external view returns (address) {}
    function setAddressAsProxy(bytes32 id, address newImplementationAddress) external {}
    function setAddress(bytes32 id, address newAddress) external {}
    function getPool() external view returns (address) {}
    function setPoolImpl(address newPoolImpl) external {}
    function getPoolConfigurator() external view returns (address) {}
    function setPoolConfiguratorImpl(address newPoolConfiguratorImpl) external {}
    function setPriceOracle(address newPriceOracle) external {}
    function getACLManager() external view returns (address) {}
    function setACLManager(address newAclManager) external {}
    function getACLAdmin() external view returns (address) {}
    function setACLAdmin(address newAclAdmin) external {}
    function getPriceOracleSentinel() external view returns (address) {}
    function setPriceOracleSentinel(address newPriceOracleSentinel) external {}
    function getPoolDataProvider() external view returns (address) {}
    function setPoolDataProvider(address newDataProvider) external {}
}
