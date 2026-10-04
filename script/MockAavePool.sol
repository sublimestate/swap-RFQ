// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAaveV3Pool} from "../src/interfaces/IAaveV3Pool.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Minimal mock of the Aave V3 pool for testnet demos: holds tokens and honors supply/withdraw.
contract MockAavePool is IAaveV3Pool {
    function supply(address asset, uint256 amount, address, uint16) external override {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        IERC20(asset).transfer(to, amount);
        return amount;
    }
}
