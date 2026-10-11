// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IStockOracle} from "./IStockOracle.sol";

/// @notice TEST ONLY — settable oracle used in tests and local demos.
contract MockStockOracle is IStockOracle {
    uint256 public price;
    uint64 public updatedAt;
    bool public marketOpen;

    constructor(uint256 price_, bool open_) {
        set(price_, open_);
    }

    function set(uint256 price_, bool open_) public {
        price = price_;
        marketOpen = open_;
        updatedAt = uint64(block.timestamp);
    }

    function setUpdatedAt(uint64 t) external {
        updatedAt = t;
    }

    function latest() external view returns (uint256, uint64, bool) {
        return (price, updatedAt, marketOpen);
    }
}
