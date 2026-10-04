# 🤖 Agent Context & Navigation Guide

Welcome, fellow AI Assistant. This file is designed to give you instant, high-signal context on the `IntentRFQ` repository so you can immediately begin developing, debugging, or analyzing without having to read through the entire codebase blindly.

## 📌 Project Overview
**IntentRFQ** is a **Uniswap V4 Hook** designed to bridge off-chain solvers with on-chain AMM liquidity. 
It intercepts trades via the `beforeSwap` callback and:
1. Validates an off-chain market-maker's cryptographic signature.
2. Settles the trade directly with the solver if they beat the AMM spot price (Zero-Slippage).
3. If the solver fails, it falls back to the AMM, performing a **Just-In-Time (JIT) withdrawal** from Aave V3 to supply the necessary liquidity.
4. Uses the **L1SLOAD** precompile (for L2s like Scroll) to prevent toxic arbitrage (LVR) by comparing the local L2 price against the L1 Ethereum Mainnet price.

## 📂 Directory Structure
- `src/IntentRFQHook.sol`: **The Core Hook**. All business logic (`_beforeSwap`, signature validation, Aave integrations) lives here.
- `src/interfaces/IAaveV3Pool.sol`: Interface for Aave V3 interactions.
- `test/IntentRFQHook.t.sol`: **Foundry Test Suite**. Contains property-based fuzz tests, signature validation tests, and mock setups.
- `script/DeployHook.s.sol`: **Deployment Script**. Uses `HookMiner` to deploy the hook.
- `solver_mock.py`: A Python script simulating the off-chain solver's intent monitoring, quote generation, and signature injection.
- `TECH_SPEC.md` & `SPEC.md`: Detailed architectural design docs.

## 🛠 Tech Stack & Commands
This is a standard **Foundry** project pinned to `solc 0.8.26`.
- **Build**: `forge build`
- **Test**: `forge test`
- **Gas Profile**: `forge test --gas-report`

## 🧠 Critical Context for Agents
When modifying this repository, keep these strict architectural constraints in mind:

### 1. Uniswap V4 Hook Permissions (`HookMiner`)
In V4, a hook's active callbacks are defined by the **leading bits of its deployed Ethereum address**. 
- If you add a new callback to `IntentRFQHook.sol` (e.g., `afterSwap`), you **MUST** update the `getHookPermissions()` return struct.
- More importantly, you **MUST** update the `flags` variable in both `test/IntentRFQHook.t.sol` and `script/DeployHook.s.sol` (e.g., `Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG`). If you do not do this, `HookMiner` will mine the wrong prefix, and the pool manager will ignore the new callback.

### 2. Transient Accounting (BeforeSwapDelta)
When the hook takes over a swap and settles it via the solver, it returns a custom `BeforeSwapDelta`:
- the **specified** component is `-params.amountSpecified`, which zeroes out the AMM leg (`amountToSwap -> 0`; the PoolManager short-circuits a zero-amount swap),
- the **unspecified** component encodes the hook's obligation (`-amountOut` for exact-in, `+amountIn` for exact-out).
The PoolManager bills that delta to the hook and deducts it from the swapper. To balance its own books the hook calls `poolManager.take()` (claims its input-token credit and forwards it to the solver) and pulls the solver's output tokens via `transferFrom`, then `sync()` + `settle()`. **Order matters: `sync()` must come BEFORE the token transfer** so `settle()` measures the balance increase — reversing them silently settles zero and the whole unlock reverts with `CurrencyNotSettled`.
If modifying token flows, remember that the hook's `take` transiently fronts pool reserves (the swapper replenishes them when settling their own bill), so the pool must hold >= the fill amount of the input token.

### 3. JIT Clawback Math
The fallback mechanism uses `LiquidityAmounts.getLiquidityForAmounts()` to dynamically convert the requested `requiredAmount` into a `liquidityDelta`. It snaps to the pool's specific `tickSpacing`. If you alter pool initialization in the tests, ensure `tickSpacing` aligns with the mocked ranges.

### 4. OpenZeppelin Dependencies
We utilize `@openzeppelin/contracts` for `Ownable`, `ECDSA`, and `MessageHashUtils`. 

## 🚀 Next Priorities (If prompted to improve the repo)
Check the **"Potential Additional Features"** section in `README.md`. High-leverage tasks include:
1. **Slippage Handling**: Upgrading the `beforeSwap` price check to account for curve depth and slippage instead of just comparing the raw spot price.
2. **Aave 100% Utilization Fix**: Implementing a 5-10% "Idle Buffer" and `try/catch` logic so that extreme Aave borrowing doesn't cascade into reverting Uniswap trades.
3. Replacing OpenZeppelin `ECDSA` with raw inline assembly `ecrecover` for gas optimization.
4. Transitioning the proprietary `SolverQuote` struct to EIP-712 Typed Data.
5. Implementing yield harvesting (`harvestYield`) to claim accrued Aave interest.

**End of Context. Happy Coding!**
