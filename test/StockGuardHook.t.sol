// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {StockGuardHook} from "../src/StockGuardHook.sol";
import {MockStockOracle} from "../src/MockStockOracle.sol";

/// TEST suite — tokenized-stock pool guarded by StockGuardHook.
/// currency0 plays the stock (e.g. tNVDA), currency1 plays tUSDC. Pool starts at 1:1.
contract StockGuardHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    StockGuardHook hook;
    MockStockOracle oracle;
    PoolKey poolKey;
    PoolId id;

    address trader = makeAddr("kyc-trader");
    bytes traderData;

    function _config(bool allowlistOnly) internal view returns (StockGuardHook.StockConfig memory) {
        return StockGuardHook.StockConfig({
            oracle: oracle,
            stockIsCurrency0: true,
            allowlistOnly: allowlistOnly,
            openFee: 3000, // 0.30%
            closedFee: 10_000, // 1.00%
            surchargePerBp: 20, // +0.002% per bp of deviation when moving away
            maxDeviationOpenBps: 200, // 2%
            maxDeviationClosedBps: 500, // 5%
            maxStaleness: 60
        });
    }

    function setUp() public {
        vm.warp(1_760_000_000);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^ (0x4444 << 144));
        deployCodeTo("StockGuardHook.sol:StockGuardHook", abi.encode(manager, address(this)), hookAddr);
        hook = StockGuardHook(hookAddr);

        oracle = new MockStockOracle(1e18, true);
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        id = poolKey.toId();

        hook.configurePool(poolKey, _config(true));
        hook.setTrustedRouter(address(swapRouter), true);
        hook.setAllowlisted(trader, true);
        traderData = abi.encode(trader);

        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function _swap(bool zeroForOne, int256 amount, bytes memory data) internal returns (BalanceDelta) {
        return swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            data
        );
    }

    function _feeFromLogs() internal view returns (uint24 fee, bool open) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("StockSwapChecked(bytes32,address,uint256,uint256,uint256,uint24,bool)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                (,,, fee, open) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint24, bool));
                return (fee, open);
            }
        }
        revert("no StockSwapChecked event");
    }

    // ---------------------------------------------------------------- happy path

    function test_openMarket_chargesOpenFee() public {
        vm.recordLogs();
        BalanceDelta d = _swap(true, -1e15, traderData);
        (uint24 fee, bool open) = _feeFromLogs();
        assertTrue(open);
        assertEq(fee, 3000);
        assertEq(d.amount0(), -1e15, "exact input spent");
        assertGt(d.amount1(), 0, "received quote token");
    }

    function test_closedMarket_chargesClosedFee() public {
        oracle.set(1e18, false);
        vm.recordLogs();
        _swap(true, -1e15, traderData);
        (uint24 fee, bool open) = _feeFromLogs();
        assertFalse(open);
        assertEq(fee, 10_000);
    }

    function test_closedFee_givesWorseExecution() public {
        uint256 snap = vm.snapshotState();
        BalanceDelta openD = _swap(true, -1e15, traderData);
        vm.revertToState(snap);
        oracle.set(1e18, false);
        BalanceDelta closedD = _swap(true, -1e15, traderData);
        assertLt(closedD.amount1(), openD.amount1());
    }

    // ---------------------------------------------------------------- oracle safety

    function test_revert_staleOracle_whileOpen() public {
        vm.warp(block.timestamp + 61);
        vm.expectRevert();
        _swap(true, -1e15, traderData);
    }

    function test_staleOracle_allowedWhileClosed() public {
        oracle.set(1e18, false);
        vm.warp(block.timestamp + 3 days); // weekend
        _swap(true, -1e15, traderData);
    }

    function test_revert_deviationTooHigh_open() public {
        oracle.set(1.03e18, true); // pool 1.00 vs oracle 1.03 → 291 bps > 200
        vm.expectRevert();
        _swap(true, -1e15, traderData);
    }

    function test_deviationWithinClosedBand_allowed() public {
        oracle.set(1.03e18, false); // 291 bps < 500 closed band
        _swap(false, -1e15, traderData);
    }

    function test_surcharge_onlyWhenMovingAwayFromOracle() public {
        oracle.set(1.01e18, true); // pool is ~99 bps below oracle

        // selling the stock pushes the pool further below the oracle → surcharge
        vm.recordLogs();
        _swap(true, -1e12, traderData);
        (uint24 awayFee,) = _feeFromLogs();

        // buying the stock moves the pool back toward the oracle → plain fee
        vm.recordLogs();
        _swap(false, -1e12, traderData);
        (uint24 towardFee,) = _feeFromLogs();

        assertEq(towardFee, 3000);
        assertGt(awayFee, towardFee);
        assertApproxEqAbs(awayFee, 3000 + 99 * 20, 40);
    }

    // ---------------------------------------------------------------- compliance

    function test_revert_traderNotAllowlisted() public {
        vm.expectRevert();
        _swap(true, -1e15, abi.encode(makeAddr("stranger")));
    }

    function test_revert_missingHookData() public {
        vm.expectRevert();
        _swap(true, -1e15, ZERO_BYTES);
    }

    function test_revert_untrustedRouter() public {
        hook.setTrustedRouter(address(swapRouter), false);
        vm.expectRevert();
        _swap(true, -1e15, traderData);
    }

    function test_allowlistRevoked_blocksTrading() public {
        _swap(true, -1e15, traderData);
        hook.setAllowlisted(trader, false);
        vm.expectRevert();
        _swap(true, -1e15, traderData);
    }

    // ---------------------------------------------------------------- admin & init

    function test_revert_nonAdminCannotConfigure() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(StockGuardHook.NotAdmin.selector);
        hook.setAllowlisted(makeAddr("attacker"), true);
    }

    function test_revert_initWithoutConfig() public {
        PoolKey memory other = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_revert_initWithStaticFee() public {
        PoolKey memory other = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        hook.configurePool(other, _config(false));
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_publicPool_noAllowlist() public {
        PoolKey memory open = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 30, IHooks(address(hook)));
        hook.configurePool(open, _config(false));
        manager.initialize(open, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(open, LIQUIDITY_PARAMS, ZERO_BYTES);
        swapRouter.swap(
            open,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    // ---------------------------------------------------------------- exact revert reasons
    // The PoolManager wraps hook reverts, so these call the hook directly as the manager.

    function _directSwap(bytes memory data) internal returns (bytes4, uint24) {
        vm.prank(address(manager));
        (bytes4 sel,, uint24 fee) = hook.beforeSwap(
            address(swapRouter),
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            data
        );
        return (sel, fee);
    }

    function test_exact_staleOracle() public {
        vm.warp(block.timestamp + 61);
        vm.expectRevert(abi.encodeWithSelector(StockGuardHook.StaleOracle.selector, 61));
        _directSwap(traderData);
    }

    function test_exact_deviationTooHigh() public {
        oracle.set(1.03e18, true);
        (,,, uint256 oraclePrice, uint256 poolPrice) = (0, 0, false, uint256(1.03e18), hook.poolStockPrice(poolKey));
        uint256 dev = ((oraclePrice - poolPrice) * 10_000) / oraclePrice;
        vm.expectRevert(abi.encodeWithSelector(StockGuardHook.DeviationTooHigh.selector, dev, 200));
        _directSwap(traderData);
    }

    function test_exact_traderNotAllowlisted() public {
        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(StockGuardHook.TraderNotAllowlisted.selector, stranger));
        _directSwap(abi.encode(stranger));
    }

    function test_exact_untrustedRouter() public {
        hook.setTrustedRouter(address(swapRouter), false);
        vm.expectRevert(abi.encodeWithSelector(StockGuardHook.UntrustedRouter.selector, address(swapRouter)));
        _directSwap(traderData);
    }

    function test_exact_onlyPoolManager() public {
        vm.expectRevert(StockGuardHook.NotPoolManager.selector);
        hook.beforeSwap(
            address(swapRouter),
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            traderData
        );
    }

    function test_returnsOverrideFlag() public {
        (bytes4 sel, uint24 fee) = _directSwap(traderData);
        assertEq(sel, IHooks.beforeSwap.selector);
        assertEq(fee, 3000 | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function test_poolPrice_matchesInitialPrice() public view {
        assertApproxEqAbs(hook.poolStockPrice(poolKey), 1e18, 1);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_feeNeverExceedsCap(uint256 oraclePrice, bool open, bool zeroForOne) public {
        oraclePrice = bound(oraclePrice, 0.96e18, 1.04e18);
        oracle.set(oraclePrice, open);
        try hook.quoteFee(poolKey, zeroForOne) returns (uint24 fee, uint256, bool, uint256, uint256) {
            assertLe(fee, hook.MAX_FEE());
            assertGe(fee, open ? 3000 : 10_000);
        } catch {
            // deviation guard tripped — acceptable outcome
        }
    }
}
