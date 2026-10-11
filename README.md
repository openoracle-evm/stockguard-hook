# stockguard-hook

**Open Oracle** · Uniswap v4 hook for tokenized-stock pools.

> ⚠️ Not yet audited and not deployed to mainnet. Do not use with real funds until the audit is published.

On every swap (`beforeSwap`) it:

1. **Compliance** — if the pool is `allowlistOnly`, the caller must be a trusted router and the trader
   (passed as `hookData = abi.encode(trader)`) must be allowlisted (KYC).
2. **Oracle freshness** — while the market is open, reverts with `StaleOracle(age)` if the price is older than `maxStaleness`.
3. **Deviation guard** — reverts with `DeviationTooHigh(bps, max)` if the pool price is too far from the oracle
   (tighter band while open, looser while closed).
4. **Dynamic fee** — `openFee` while NYSE is open, `closedFee` while closed, plus `surchargePerBp × deviation`
   for swaps that push the pool further away from the oracle. Capped at 5%.

Pools must be initialised with `LPFeeLibrary.DYNAMIC_FEE_FLAG` and configured by the admin first.

```
src/StockGuardHook.sol     the hook (implements IHooks directly)
src/IStockOracle.sol       price, updatedAt, marketOpen
src/MockStockOracle.sol    settable oracle for tests
test/StockGuardHook.t.sol  24 tests incl. fuzz (512 runs)
```

```bash
forge build
forge test
```

Assumes both tokens use 18 decimals. Hook address must encode `BEFORE_INITIALIZE | BEFORE_SWAP` flags
(mine it with HookMiner before any real deployment).

## Install

```bash
git clone --recursive https://github.com/openoracle-evm/stockguard-hook
cd stockguard-hook
forge test
```

## License

MIT
