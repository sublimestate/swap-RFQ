# Technical Specification: Uniswap V4 Intent-Based RFQ Hook

## 1. Introduction & Objectives
This technical specification outlines the architecture and implementation details for a highly optimized, synchronous Request-For-Quote (RFQ) smart contract hook for Uniswap V4. The hook enables zero-slippage trades by bridging off-chain solvers with on-chain liquidity. It includes advanced features to optimize capital efficiency via synthetic liquidity lending and protects against Loss Versus Rebalancing (LVR) using Layer 1 state reads.

## 2. System Architecture

The system consists of two primary components:
1. **On-Chain Hook Contract**: A Uniswap V4 singleton hook implementing the `IHooks` interface.
2. **Off-Chain Solver Mock**: An external service that monitors the mempool, generates quotes, and signs payloads for better trade execution.

### High-Level Workflow
1. User submits a swap transaction.
2. The Hook intercepts the swap via the `beforeSwap` callback.
3. Hook unpacks `hookData` to verify an off-chain solver's signed quote.
4. **Execution Paths**:
   - **Solver Path (NoOp)**: If the solver's price is better than the AMM price, the hook facilitates direct settlement and returns a "NoOp" flag to bypass standard AMM math.
   - **AMM Fallback**: If no valid solver quote is present or the price is worse, the trade executes against the standard Uniswap pool.

## 3. Smart Contract Design

### 3.1 Hook Implementation
- **Base Framework**: Must inherit from the official Uniswap `v4-template` and implement `IHooks`.
- **Target Callbacks**: Primarily utilizes `beforeSwap`.

### 3.2 Verification and Price Comparison
- The contract extracts `hookData` from the swap parameters.
- Validates the cryptographic signature of the solver to prevent spoofing.
- Calculates the current AMM spot price and compares it against the signed solver price.

### 3.3 NoOp Delta Accounting
- To settle trades via solvers without triggering the Pool Manager's default AMM math, the hook utilizes the `BeforeSwapDelta` library.
- By returning a custom delta flag (NoOp), the contract instructs the pool manager that the token deltas have already been fully resolved by the hook.

## 4. Core Features (v1.0)

### 4.1 Synthetic Idle Liquidity Lending (Clawback)
Traditional AMM liquidity remains idle when solvers win the majority of volume. To maximize capital efficiency:
- **Idle Deployment**: The hook automatically routes inactive pool liquidity to yield-generating protocols (e.g., Aave, Spark).
- **Just-In-Time (JIT) Clawback**: If the solver path fails and the AMM fallback is triggered, the hook calculates the exact minimum liquidity required for the swap. It synchronously withdraws ("claws back") this exact amount from the lending protocol to satisfy the trade seamlessly.

### 4.2 L1SLOAD LVR Protection
Protects Liquidity Providers (LPs) from toxic cross-chain arbitrage when deployed on L2s (e.g., Scroll).
- **State Reading**: Uses the `L1SLOAD` precompile to fetch the L1 (Ethereum mainnet) spot price of the assets synchronously.
- **Dynamic Defense**: During `beforeSwap`, the hook compares the local L2 AMM price against the L1 oracle price. If a severe discrepancy is detected (indicating toxic flow), the hook will either:
  - Revert the swap transaction to block the arbitrage.
  - Impose a heavy dynamic fee on the attacker to internalize the LVR.

## 5. Off-Chain Solver Mock
A lightweight service built in TypeScript or Python.
- **Mempool Monitoring**: Listens for pending user swap intents.
- **Quote Generation**: Calculates a price slightly better than the on-chain AMM price to ensure solver execution.
- **Payload Construction**: Formats and signs the execution payload.
- **Transaction Injection**: Injects the signed payload into the `hookData` of the user's transaction.

## 6. Future Extensions (v2.0 Roadmap)

### ERC-7683 Integration
- Replace proprietary solver signature formats with the native ERC-7683 `CrossChainOrder` struct.
- Enables seamless integration with global intent networks (e.g., UniswapX, Across).
- Expands available liquidity by allowing any compliant solver to fulfill orders.

## 7. Testing & Quality Assurance
- **Framework**: Foundry
- **Fuzz Testing**: Exhaustive property-based fuzzing is mandatory.
  - **Signature Spoofing**: Guarantee mathematically that solver signatures cannot be forged or replayed.
  - **LVR Defense**: Ensure `L1SLOAD` price deviations trigger defensive measures accurately under all market conditions.
  - **Liquidity Clawback**: Verify that JIT withdrawal logic never bricks the pool state or results in insolvency.
- **Gas Optimization**: Strict profiling to ensure hook execution remains competitive, particularly regarding the overhead of L1 state reads and lending protocol interactions.

## 8. Technology Stack
- **Smart Contracts**: Solidity, Uniswap V4 Core/Periphery
- **Development & Testing**: Foundry (Rust-based)
- **Off-Chain Services**: TypeScript / Python
- **Target Networks**: Scroll (for L1SLOAD capabilities), Ethereum Layer 2s
