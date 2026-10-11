// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {IStockOracle} from "./IStockOracle.sol";

/// @title StockGuardHook (TEST)
/// @notice Uniswap v4 hook for tokenized-equity pools. On every swap it:
///         1. reads the stock oracle (price, freshness, market open/closed),
///         2. rejects swaps on stale prices while the market is open,
///         3. rejects swaps when the pool has drifted too far from the oracle,
///         4. charges a dynamic fee: higher while the market is closed, plus a
///            surcharge for swaps that push the pool further away from the oracle,
///         5. optionally restricts trading to allowlisted traders (KYC) via trusted routers.
/// @dev TEST / DEMO CODE — unaudited. Assumes both pool tokens use 18 decimals.
contract StockGuardHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    struct StockConfig {
        IStockOracle oracle;
        bool stockIsCurrency0; // which side of the pool is the stock token
        bool allowlistOnly; // require KYC'd traders
        uint24 openFee; // pips (1e6 = 100%) while the market is open
        uint24 closedFee; // pips while the market is closed
        uint24 surchargePerBp; // extra pips per bp of deviation, only when moving away from the oracle
        uint16 maxDeviationOpenBps; // hard stop while open
        uint16 maxDeviationClosedBps; // hard stop while closed (looser — oracle is not updating)
        uint32 maxStaleness; // seconds; enforced only while the market is open
    }

    IPoolManager public immutable poolManager;
    address public admin;

    mapping(PoolId => StockConfig) public configs;
    mapping(PoolId => bool) public configured;
    mapping(address => bool) public allowlisted;
    mapping(address => bool) public trustedRouter;

    uint24 public constant MAX_FEE = 50_000; // 5% cap

    event PoolConfigured(PoolId indexed id, address oracle, bool stockIsCurrency0);
    event Allowlisted(address indexed account, bool allowed);
    event RouterTrusted(address indexed router, bool trusted);
    event StockSwapChecked(
        PoolId indexed id, address indexed trader, uint256 oraclePrice, uint256 poolPrice, uint256 deviationBps, uint24 fee, bool marketOpen
    );

    error NotPoolManager();
    error NotAdmin();
    error HookNotImplemented();
    error PoolNotConfigured();
    error MustUseDynamicFee();
    error StaleOracle(uint256 age);
    error DeviationTooHigh(uint256 deviationBps, uint256 maxBps);
    error UntrustedRouter(address router);
    error TraderNotAllowlisted(address trader);
    error InvalidConfig();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(IPoolManager manager, address admin_) {
        poolManager = manager;
        admin = admin_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
    }

    // ------------------------------------------------------------------ admin

    function configurePool(PoolKey calldata key, StockConfig calldata cfg) external onlyAdmin {
        if (
            address(cfg.oracle) == address(0) || cfg.openFee > MAX_FEE || cfg.closedFee > MAX_FEE
                || cfg.maxDeviationOpenBps == 0 || cfg.maxDeviationClosedBps < cfg.maxDeviationOpenBps
        ) revert InvalidConfig();
        PoolId id = key.toId();
        configs[id] = cfg;
        configured[id] = true;
        emit PoolConfigured(id, address(cfg.oracle), cfg.stockIsCurrency0);
    }

    function setAllowlisted(address account, bool allowed) external onlyAdmin {
        allowlisted[account] = allowed;
        emit Allowlisted(account, allowed);
    }

    function setTrustedRouter(address router, bool trusted) external onlyAdmin {
        trustedRouter[router] = trusted;
        emit RouterTrusted(router, trusted);
    }

    function transferAdmin(address next) external onlyAdmin {
        admin = next;
    }

    // ------------------------------------------------------------------ views

    /// @notice Stock price implied by the pool, quoted in the paired token (1e18).
    function poolStockPrice(PoolKey calldata key) public view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        // price of currency0 in currency1 = sqrtP^2 / 2^192, scaled to 1e18
        uint256 priceX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        uint256 p0in1 = FullMath.mulDiv(priceX128, 1e18, 1 << 128);
        if (configs[key.toId()].stockIsCurrency0) return p0in1;
        return p0in1 == 0 ? type(uint256).max : 1e36 / p0in1;
    }

    /// @notice Fee the hook would charge right now for a swap in the given direction.
    /// @return fee LP fee in pips
    /// @return deviationBps |pool − oracle| / oracle, in basis points
    /// @return marketOpen oracle's market status
    function quoteFee(PoolKey calldata key, bool zeroForOne)
        public
        view
        returns (uint24 fee, uint256 deviationBps, bool marketOpen, uint256 oraclePrice, uint256 poolPrice)
    {
        PoolId id = key.toId();
        if (!configured[id]) revert PoolNotConfigured();
        StockConfig memory cfg = configs[id];

        uint64 updatedAt;
        (oraclePrice, updatedAt, marketOpen) = cfg.oracle.latest();
        if (marketOpen) {
            uint256 age = block.timestamp - updatedAt;
            if (age > cfg.maxStaleness) revert StaleOracle(age);
        }

        poolPrice = poolStockPrice(key);
        uint256 diff = poolPrice > oraclePrice ? poolPrice - oraclePrice : oraclePrice - poolPrice;
        deviationBps = FullMath.mulDiv(diff, 10_000, oraclePrice);

        uint256 maxDev = marketOpen ? cfg.maxDeviationOpenBps : cfg.maxDeviationClosedBps;
        if (deviationBps > maxDev) revert DeviationTooHigh(deviationBps, maxDev);

        uint256 f = marketOpen ? cfg.openFee : cfg.closedFee;

        // zeroForOne lowers the price of currency0. Work out whether this swap
        // pushes the *stock* price up or down, and whether that is away from the oracle.
        bool stockPriceDown = cfg.stockIsCurrency0 ? zeroForOne : !zeroForOne;
        bool poolAbove = poolPrice > oraclePrice;
        bool movingAway = (poolAbove && !stockPriceDown) || (!poolAbove && stockPriceDown && diff != 0);
        if (movingAway) f += deviationBps * cfg.surchargePerBp;

        // casting is safe: f is capped at MAX_FEE (< 2^24)
        // forge-lint: disable-next-line(unsafe-typecast)
        fee = uint24(f > MAX_FEE ? MAX_FEE : f);
    }

    // ------------------------------------------------------------------ hooks

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        if (!configured[key.toId()]) revert PoolNotConfigured();
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        address trader = sender;
        if (configs[id].allowlistOnly) {
            if (!trustedRouter[sender]) revert UntrustedRouter(sender);
            trader = hookData.length >= 32 ? abi.decode(hookData, (address)) : address(0);
            if (!allowlisted[trader]) revert TraderNotAllowlisted(trader);
        }

        (uint24 fee, uint256 dev, bool open, uint256 oraclePrice, uint256 poolPrice) = quoteFee(key, params.zeroForOne);
        emit StockSwapChecked(id, trader, oraclePrice, poolPrice, dev, fee, open);

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // ------------------------------------------------------------------ unused

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
