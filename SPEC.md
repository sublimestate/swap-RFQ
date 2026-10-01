Product Specification: Uniswap V4 Intent-Based RFQ Hook with Synthetic Liquidity & LVR Defense
1. Product Overview
The objective of this project is to build a highly optimized, synchronous Request-For-Quote (RFQ) smart contract hook for Uniswap V4. The hook acts as a bridge between off-chain professional market makers (solvers) and on-chain decentralized liquidity.
By intercepting trades before they hit the standard Automated Market Maker (AMM) curve, the hook allows solvers to fill user orders at zero slippage and better prices. If no solver is present, the hook securely falls back to the standard Uniswap V4 liquidity pool. Furthermore, the architecture protects the fallback liquidity from toxic arbitrage (LVR) and ensures idle capital is highly efficient by routing it to external lending protocols.
2. Core Architecture: The "NoOp" Engine
The foundation of this protocol relies on Uniswap V4's custom accounting features and the beforeSwap callback.
Interception: When a user submits a swap transaction, the hook intercepts the call via the beforeSwap function.
Verification: The hook unpacks the hookData payload provided in the swap parameters to check for a cryptographically signed quote from an off-chain solver.
Price Comparison & Execution: The contract calculates the current AMM pool price. If the solver's signed price is superior, the hook facilitates a direct token transfer between the user and the solver.
The NoOp Return: To prevent the Uniswap Pool Manager from executing its default AMM math after the solver settles the trade, the hook utilizes the BeforeSwapDelta library to return a custom delta flag (often referred to as a NoOp), instructing the pool that the swap has already been completely handled.
Fallback: If the solver's signature is missing, invalid, or offers a worse price than the pool, the hook ignores the NoOp path and allows the transaction to execute against the standard Uniswap pool liquidity.
3. Required Features (v1.0)
Feature A: Synthetic Idle Liquidity Lending (Clawback)
Traditional AMM liquidity sits idle when solvers take the majority of trading volume. This feature ensures capital efficiency.
Idle Deployment: The hook automatically deposits inactive pool liquidity into a yield-generating protocol (e.g., Aave or Spark).
Just-In-Time Clawback: When a trade fails to find a solver and must execute against the standard Uniswap pool, the hook automatically "claws back" the exact minimum liquidity required to satisfy that specific swap from the lending protocol, executing the trade as if the liquidity had never left.
Feature B: L1SLOAD LVR Protection
Liquidity providers suffer Loss Versus Rebalancing (LVR) when cross-chain arbitrageurs exploit stale prices on Layer 2 networks. This feature defends the pool during fallback AMM swaps.
State Reading: Deployed on an L2 like Scroll, the hook utilizes the L1SLOAD precompile to instantly read the Layer 1 (Ethereum mainnet) spot price of the assets.
Dynamic Defense: During the beforeSwap execution, if the hook detects a severe discrepancy between the L2 pool price and the L1 oracle price (indicating an impending toxic arbitrage transaction), it automatically blocks the swap or applies a heavy dynamic fee to the attacker.
4. Nice-to-Have Features (v2.0 Roadmap)
ERC-7683 Cross-Chain Intent Standardization
Currently shelved for v1.0, the v2.0 roadmap will integrate the ERC-7683 standard to allow the hook to plug seamlessly into global solver networks.
Instead of using a proprietary signature format for the solver's quote, the hook will be upgraded to natively parse the CrossChainOrder struct defined by ERC-7683.
This will allow the hook to accept order fulfillments from any compliant intent network or solver (such as UniswapX or Across), significantly deepening the available liquidity for users.
5. Technical Stack & Development Requirements
Framework: Foundry (Rust-based execution). The project must be built on top of the official Uniswap v4-template repository.
Smart Contracts (Solidity): Development of the singleton hook contract implementing the IHooks interface. Strict adherence to gas optimization is required.
Off-Chain Solver Mock (TypeScript/Python): A lightweight script that monitors the mempool, generates a slightly improved price compared to the AMM, formats the payload, signs it, and injects it into the transaction to trigger the NoOp execution path.
Testing (Fuzzing): Exhaustive property-based fuzz testing using Foundry to mathematically guarantee that solver signatures cannot be spoofed, the LVR defense triggers at correct L1/L2 price deviations, and the liquidity clawback never bricks the pool state.