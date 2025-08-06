// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.20;

import {ITSwapPool} from "../interfaces/ITSwapPool.sol";
import {IPoolFactory} from "../interfaces/IPoolFactory.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract OracleUpgradeable is Initializable {
    address private s_poolFactory;

    function __Oracle_init(address poolFactoryAddress) internal initializer {
        __Oracle_init_unchained(poolFactoryAddress);
    }

    function __Oracle_init_unchained(
        address poolFactoryAddress
    ) internal onlyInitializing {
        require(
            poolFactoryAddress != address(0),
            "Oracle: factory address is zero"
        );
        s_poolFactory = poolFactoryAddress;
    }

    function getPriceInWeth(address token) public view returns (uint256) {
        address swapPoolOfToken = IPoolFactory(s_poolFactory).getPool(token);
        require(
            swapPoolOfToken != address(0),
            "Oracle: no pool found for token"
        );
        return ITSwapPool(swapPoolOfToken).getPriceOfOnePoolTokenInWeth();
    }

    function getPrice(address token) external view returns (uint256) {
        return getPriceInWeth(token);
    }

    function getPoolFactoryAddress() external view returns (address) {
        return s_poolFactory;
    }
}
