// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal price feed for a tokenized equity.
/// @dev `price` is the stock price quoted in the paired token, scaled to 1e18.
interface IStockOracle {
    function latest() external view returns (uint256 price, uint64 updatedAt, bool marketOpen);
}
