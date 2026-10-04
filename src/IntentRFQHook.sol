// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAaveV3Pool} from "./interfaces/IAaveV3Pool.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapMath} from "v4-core/src/libraries/SwapMath.sol";
import {LiquidityMath} from "v4-core/src/libraries/LiquidityMath.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @title IntentRFQHook
/// @notice Uniswap V4 hook for intent-based RFQ execution.
/// @dev Intercepts swaps in `beforeSwap`. If an authorized off-chain solver quotes a price
///      better than the AMM spot price, the hook takes over the swap entirely:
///      - the returned `BeforeSwapDelta` zeroes out the AMM leg (specified delta cancels
///        `amountSpecified`) and encodes the hook's obligation (unspecified delta),
///      - the hook claims the user's input tokens via `take` and forwards them to the solver,
///      - the hook pulls the solver's output tokens via `transferFrom` and settles them,
///      so the user receives exactly the quoted amount with zero slippage.
///      If no valid solver quote is present, the swap falls back to the AMM with
///      LVR protection and JIT liquidity sourced from Aave V3.
contract IntentRFQHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    IAaveV3Pool public immutable aavePool;

    mapping(address => bool) public isAuthorizedSolver;
    mapping(address => uint256) public solverNonces;
    mapping(address => bool) public isAaveApproved; // Tracks infinite approvals to save gas

    // Scroll L1SLOAD precompile address
    address public constant L1_SLOAD_PRECOMPILE = 0x0000000000000000000000000000000000000101;

    address public immutable l1PoolAddress;
    uint256 public constant MAX_SQRT_PRICE_DEVIATION_BIPS = 25; // ~0.5% price deviation

    /// @notice Share of hook-owned position liquidity (in bips) that sweepIdleLiquidity
    ///         always leaves in the AMM. This idle buffer keeps baseline reserves in the
    ///         pool so fallback swaps still execute when the lending protocol is
    ///         illiquid (e.g. 100% utilization) and JIT cannot be served.
    uint256 public idleBufferBips = 1000; // 10%

    /// @notice Maximum tick-boundary steps when simulating the AMM swap for quote
    ///         comparison. If a swap would cross more boundaries, the quote is
    ///         rejected (safe AMM fallback) rather than estimated.
    uint256 private constant MAX_QUOTE_SIM_STEPS = 64;

    event SolverFill(
        PoolId indexed poolId,
        address indexed solver,
        address indexed taker,
        uint256 amountIn,
        uint256 amountOut
    );
    event LVRBlocked(PoolId indexed poolId, uint160 sqrtPriceX96L2, uint160 sqrtPriceX96L1);
    event JITLiquidityAdded(PoolId indexed poolId, address indexed token, uint256 amount, uint128 liquidity);
    event IdleLiquiditySwept(PoolId indexed poolId, uint256 amount0, uint256 amount1);
    event IdleBufferSet(uint256 bips);

    error LVRAttackDetected();

    constructor(IPoolManager _poolManager, address _aavePool, address _l1PoolAddress)
        BaseHook(_poolManager)
        Ownable(msg.sender)
    {
        aavePool = IAaveV3Pool(_aavePool);
        l1PoolAddress = _l1PoolAddress;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Authorize or deauthorize a solver
    function setAuthorizedSolver(address solver, bool authorized) external onlyOwner {
        isAuthorizedSolver[solver] = authorized;
    }

    /// @notice Sets the idle buffer kept in the AMM by sweepIdleLiquidity.
    /// @param bips Buffer in basis points (1000 = 10%). Capped at 50% — a larger
    ///        buffer would defeat the purpose of sweeping idle liquidity to yield.
    function setIdleBufferBips(uint256 bips) external onlyOwner {
        require(bips <= 5000, "buffer too high");
        idleBufferBips = bips;
        emit IdleBufferSet(bips);
    }

    /// @notice Off-chain solver quote, provided by the swapper via hookData and signed by the solver.
    /// @dev The signature binds the pool, swap direction, amounts, nonce and deadline to prevent
    ///      cross-pool and cross-direction replay of quotes.
    struct SolverQuote {
        address solver;
        uint256 amountIn;
        uint256 amountOut;
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (hookData.length > 0) {
            SolverQuote memory quote = abi.decode(hookData, (SolverQuote));

            if (_isValidSolverFill(key, params, quote)) {
                _settleWithSolver(key, params, quote);

                // Take over the swap entirely:
                // - the specified delta cancels the AMM leg (amountToSwap -> 0),
                // - the unspecified delta encodes the hook's obligation to the PoolManager,
                //   which the PoolManager bills to the hook and deducts from the swapper.
                int256 deltaSpecified = -params.amountSpecified;
                int256 deltaUnspecified =
                    params.amountSpecified < 0 ? -int256(quote.amountOut) : int256(quote.amountIn);

                emit SolverFill(key.toId(), quote.solver, sender, quote.amountIn, quote.amountOut);

                return (
                    BaseHook.beforeSwap.selector,
                    toBeforeSwapDelta(int128(deltaSpecified), int128(deltaUnspecified)),
                    0
                );
            }
            // Invalid, stale or uncompetitive quote: fall through to the AMM path below.
        }

        // AMM fallback path.
        _checkLVRProtection(key);

        // JIT Clawback: pull output-side liquidity from the lending protocol just in time.
        _jitClawback(key, params);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Checks that a solver quote is well-formed, fresh, signed by an authorized solver,
    ///         matches the swap being executed, and beats the AMM spot price.
    /// @dev Never reverts: any failure falls back to AMM execution.
    function _isValidSolverFill(PoolKey calldata key, SwapParams calldata params, SolverQuote memory quote)
        internal
        returns (bool)
    {
        // The quote must be for the exact amounts being swapped.
        if (params.amountSpecified < 0) {
            if (quote.amountIn != uint256(-params.amountSpecified)) return false;
        } else {
            if (quote.amountOut != uint256(params.amountSpecified)) return false;
        }

        // Native-token output settlement is not supported in v1; fall back to the AMM.
        Currency currencyOut = params.zeroForOne ? key.currency1 : key.currency0;
        if (Currency.unwrap(currencyOut) == address(0)) return false;

        if (!_verifySolverSignature(key, params.zeroForOne, quote)) return false;

        // The solver must beat the AMM's TRUE execution price — not the marginal
        // spot price. The simulation replicates the PoolManager's own swap math
        // (LP fees, price impact, concentrated liquidity across ticks). If it
        // cannot complete exactly, or reverts for any reason, the quote is
        // rejected and the swap safely falls back to the AMM.
        try this.simulateAMMSwap(key, params) returns (
            uint256 ammAmountIn, uint256 ammAmountOut, bool exact
        ) {
            if (!exact) return false;
            if (params.amountSpecified < 0) {
                // Exact input: solver must deliver at least the AMM's output.
                return quote.amountOut >= ammAmountOut;
            } else {
                // Exact output: solver must charge at most the AMM's required input.
                return quote.amountIn <= ammAmountIn;
            }
        } catch {
            return false;
        }
    }

    // TODO(Optimization): Replace OpenZeppelin ECDSA with raw inline assembly `ecrecover`
    // to reduce gas overhead by ~12,000 units on the hot path since this executes pre-swap.
    /// @dev Returns false (instead of reverting) on any validation failure so the swap
    ///      can fall back to AMM execution rather than bricking the user's transaction.
    function _verifySolverSignature(PoolKey calldata key, bool zeroForOne, SolverQuote memory quote)
        internal
        returns (bool)
    {
        if (block.timestamp > quote.deadline) return false;
        if (quote.nonce != solverNonces[quote.solver]) return false;

        // Bind the quote to this pool and direction to prevent cross-pool replay.
        bytes32 messageHash = keccak256(
            abi.encode(
                key.toId(), zeroForOne, quote.solver, quote.amountIn, quote.amountOut, quote.nonce, quote.deadline
            )
        );

        address recoveredSigner =
            ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(messageHash), quote.signature);

        if (recoveredSigner != quote.solver || !isAuthorizedSolver[quote.solver]) return false;

        // Increment nonce only once the signature is fully valid.
        solverNonces[quote.solver]++;
        return true;
    }

    /// @notice Simulates the AMM swap tick-by-tick against live pool state, replicating
    ///         the PoolManager's swap math: LP fees, price impact, and concentrated
    ///         liquidity across tick boundaries.
    /// @dev External so callers can try/catch it. A revert — or an inexact result —
    ///      must always resolve to AMM fallback, never to bricking the user's swap.
    ///      Uses the pool's LP fee only; if a protocol fee were set, ignoring it
    ///      overestimates AMM output, which is the safe direction (higher bar for
    ///      the solver, never a worse fill for the user).
    /// @return totalAmountIn Total input the AMM would consume, including fees.
    /// @return totalAmountOut Total output the AMM would produce.
    /// @return exact False if the simulation hit the step bound or ran out of
    ///         liquidity/range: the totals are then a lower bound, not the true price.
    function simulateAMMSwap(PoolKey calldata key, SwapParams calldata params)
        external
        view
        returns (uint256 totalAmountIn, uint256 totalAmountOut, bool exact)
    {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = poolManager.getSlot0(poolId);

        QuoteSim memory sim = QuoteSim({
            sqrtPrice: sqrtPriceX96,
            tick: tick,
            liquidity: poolManager.getLiquidity(poolId),
            amountRemaining: params.amountSpecified,
            amountIn: 0,
            amountOut: 0,
            spacing: key.tickSpacing,
            zeroForOne: params.zeroForOne,
            exactInput: params.amountSpecified < 0,
            lpFee: lpFee,
            poolId: poolId
        });

        for (uint256 i = 0; i < MAX_QUOTE_SIM_STEPS;) {
            (bool done, bool ok) = _quoteSimStep(sim);
            if (done) return (sim.amountIn, sim.amountOut, ok);
            unchecked {
                ++i;
            }
        }
        return (sim.amountIn, sim.amountOut, false);
    }

    /// @dev Mutable state for the AMM swap simulation (struct keeps stack shallow).
    struct QuoteSim {
        uint160 sqrtPrice;
        int24 tick;
        uint128 liquidity;
        int256 amountRemaining;
        uint256 amountIn;
        uint256 amountOut;
        int24 spacing;
        bool zeroForOne;
        bool exactInput;
        uint24 lpFee;
        PoolId poolId;
    }

    /// @dev Executes one step of the simulation, targeting the next initialized tick
    ///      (or word edge), exactly mirroring Pool.swap's loop.
    /// @return done True when the simulation completed (ok distinguishes exact vs inexact).
    function _quoteSimStep(QuoteSim memory sim) internal view returns (bool done, bool ok) {
        if (sim.amountRemaining == 0) return (true, true);
        if (sim.liquidity == 0) return (true, false);

        (int24 tickNext, bool initialized) =
            _nextInitializedTick(sim.poolId, sim.tick, sim.spacing, sim.zeroForOne);
        // The bitmap is unaware of the min/max tick bounds — clamp like Pool.swap does.
        if (tickNext < TickMath.MIN_TICK) tickNext = TickMath.MIN_TICK;
        if (tickNext > TickMath.MAX_TICK) tickNext = TickMath.MAX_TICK;
        uint160 targetPrice = TickMath.getSqrtPriceAtTick(tickNext);

        (uint160 sqrtPriceNext, uint256 stepIn, uint256 stepOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(sim.sqrtPrice, targetPrice, sim.liquidity, sim.amountRemaining, sim.lpFee);

        if (sim.exactInput) {
            sim.amountRemaining += int256(stepIn + feeAmount);
            sim.amountOut += stepOut;
        } else {
            sim.amountRemaining -= int256(stepOut);
            sim.amountIn += stepIn + feeAmount;
        }
        sim.sqrtPrice = sqrtPriceNext;

        if (sqrtPriceNext == targetPrice) {
            if (tickNext == TickMath.MIN_TICK || tickNext == TickMath.MAX_TICK) {
                return (true, false); // ran out of price range with amount remaining
            }
            if (initialized) {
                (, int128 liquidityNet) = poolManager.getTickLiquidity(sim.poolId, tickNext);
                sim.liquidity = LiquidityMath.addDelta(
                    sim.liquidity, sim.zeroForOne ? -liquidityNet : liquidityNet
                );
            }
            sim.tick = sim.zeroForOne ? tickNext - 1 : tickNext;
        }
        return (false, false);
    }

    /// @dev Replicates TickBitmap.nextInitializedTickWithinOneWord against the pool's
    ///      tick bitmap (fetched via StateLibrary). Searches a single word; when no
    ///      initialized tick is found, returns the word edge uninitialized and the
    ///      outer loop continues from the adjacent word.
    function _nextInitializedTick(PoolId poolId, int24 tick, int24 spacing, bool lte)
        internal
        view
        returns (int24 next, bool initialized)
    {
        int24 compressed = _compressTick(tick, spacing);
        if (lte) {
            (int16 wordPos, uint8 bitPos) = _tickPosition(compressed);
            uint256 masked =
                poolManager.getTickBitmap(poolId, wordPos) & (type(uint256).max >> (255 - bitPos));
            if (masked != 0) {
                uint8 msb = BitMath.mostSignificantBit(masked);
                next = (compressed - int24(uint24(bitPos - msb))) * spacing;
                initialized = true;
            } else {
                next = (compressed - int24(uint24(bitPos))) * spacing;
                initialized = false;
            }
        } else {
            int24 c1 = compressed + 1;
            (int16 wordPos, uint8 bitPos) = _tickPosition(c1);
            uint256 masked = poolManager.getTickBitmap(poolId, wordPos) & (~((1 << bitPos) - 1));
            if (masked != 0) {
                uint8 lsb = BitMath.leastSignificantBit(masked);
                next = (c1 + int24(uint24(lsb - bitPos))) * spacing;
                initialized = true;
            } else {
                next = (c1 + int24(uint24(255 - bitPos))) * spacing;
                initialized = false;
            }
        }
    }

    /// @dev Tick divided by spacing, rounded toward negative infinity.
    function _compressTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed -= 1;
        return compressed;
    }

    /// @dev Word position and bit position of a compressed tick in the bitmap.
    function _tickPosition(int24 compressed) internal pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(compressed >> 8);
        bitPos = uint8(uint24(compressed) & 0xff);
    }

    /// @notice Settles a solver fill: the hook takes the user's input tokens (which the swapper
    ///         replenishes when settling their own bill) and forwards them to the solver, then
    ///         pulls the solver's output tokens and settles its own obligation.
    function _settleWithSolver(PoolKey calldata key, SwapParams calldata params, SolverQuote memory quote)
        internal
    {
        Currency currencyIn = params.zeroForOne ? key.currency0 : key.currency1;
        Currency currencyOut = params.zeroForOne ? key.currency1 : key.currency0;

        uint256 amountIn = quote.amountIn;
        uint256 amountOut = quote.amountOut;

        // 1. The hook is owed `amountIn` of currencyIn (positive delta from the returned
        //    hookDelta). Claim it from the PoolManager — the swapper's own settlement
        //    replenishes the pool — and forward it to the solver as payment.
        //    Note: this transiently fronts pool reserves; the pool must hold >= amountIn
        //    of currencyIn at this point (true for any pool with live liquidity).
        poolManager.take(currencyIn, quote.solver, amountIn);

        // 2. The hook owes `amountOut` of currencyOut. Pull it from the solver
        //    (the solver must have approved this hook) and settle the obligation.
        //    Note: sync() must come BEFORE the transfer so settle() measures the increase.
        poolManager.sync(currencyOut);
        IERC20(Currency.unwrap(currencyOut)).transferFrom(quote.solver, address(poolManager), amountOut);
        poolManager.settle();
    }

    /// @notice Reverts if the L2 pool price deviates too far from the L1 reference price,
    ///         which indicates toxic arbitrage (LVR) in progress.
    /// @dev The L1SLOAD read is a placeholder: on chains without the precompile the check
    ///      is skipped. See the roadmap for a production implementation.
    function _checkLVRProtection(PoolKey calldata key) internal {
        if (l1PoolAddress == address(0)) return;

        // Get the L2 AMM price
        (uint160 sqrtPriceX96L2,,,) = poolManager.getSlot0(key.toId());

        // Read L1 spot price via L1SLOAD precompile
        if (L1_SLOAD_PRECOMPILE.code.length > 0) {
            (bool success, bytes memory data) =
                L1_SLOAD_PRECOMPILE.staticcall(abi.encodePacked(l1PoolAddress, uint256(0)));

            if (success && data.length >= 32) {
                uint256 slot0Data = abi.decode(data, (uint256));
                // sqrtPriceX96 is the lowest 160 bits of Slot0
                uint160 sqrtPriceX96L1 = uint160(slot0Data & 0x00FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF);

                if (sqrtPriceX96L1 > 0 && sqrtPriceX96L2 > 0) {
                    uint256 diff = sqrtPriceX96L1 > sqrtPriceX96L2
                        ? sqrtPriceX96L1 - sqrtPriceX96L2
                        : sqrtPriceX96L2 - sqrtPriceX96L1;

                    uint256 deviationBips = (diff * 10000) / sqrtPriceX96L2;

                    if (deviationBips > MAX_SQRT_PRICE_DEVIATION_BIPS) {
                        emit LVRBlocked(key.toId(), sqrtPriceX96L2, sqrtPriceX96L1);
                        revert LVRAttackDetected();
                    }
                }
            }
        }
    }

    /// @notice Just-in-time liquidity: withdraws the swap's OUTPUT token from the lending
    ///         protocol and adds it as single-sided liquidity just ahead of the price direction,
    ///         so the fallback AMM swap traverses deeper reserves.
    /// @dev Single-sided liquidity is only nonzero out of range on the appropriate side
    ///      (an in-range single-sided position computes to zero liquidity), hence:
    ///      - zeroForOne (price moves down): token1-only range BELOW the current price.
    ///      - oneForZero (price moves up):   token0-only range ABOVE the current price.
    ///      The position is owned by the hook (salt 0) and is permanent — use
    ///      `sweepIdleLiquidity` to recycle it back into the lending protocol.
    ///      Best-effort: never bricks the user's swap. If the lending protocol cannot
    ///      serve the withdrawal (e.g. 100% utilization), JIT is skipped and the swap
    ///      executes against the AMM's own reserves.
    function _jitClawback(PoolKey calldata key, SwapParams calldata params) internal {
        // Calculate exact token amount required for the fallback swap
        uint256 requiredAmount = uint256(params.amountSpecified > 0 ? params.amountSpecified : -params.amountSpecified);

        // JIT liquidity must deepen the OUTPUT side of the swap — that is what determines
        // the execution price. (Withdrawing the input token would not improve the fill.)
        bool zeroForOne = params.zeroForOne;
        address tokenToWithdraw = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        if (tokenToWithdraw == address(0)) return;

        // 1. Just-in-time withdrawal from the yield-generating protocol.
        //    Graceful degradation: a failed or empty withdrawal skips JIT entirely —
        //    transient lending-protocol illiquidity must not brick DEX trade execution.
        uint256 withdrawn;
        try aavePool.withdraw(tokenToWithdraw, requiredAmount, address(this)) returns (uint256 amount) {
            withdrawn = amount;
        } catch {
            return;
        }
        if (withdrawn == 0) return;

        int24 spacing = key.tickSpacing;
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        // Snap the current tick down to a usable boundary
        int24 baseTick = (currentTick / spacing) * spacing;
        if (currentTick < 0 && currentTick % spacing != 0) baseTick -= spacing;

        // Width of the JIT range (covers typical price impact of the incoming swap)
        int24 width = 3 * spacing;
        int24 tickLower;
        int24 tickUpper;
        if (zeroForOne) {
            tickUpper = baseTick;
            tickLower = baseTick - width;
        } else {
            tickLower = baseTick + spacing;
            tickUpper = baseTick + spacing + width;
        }

        // Best-effort: skip JIT rather than reverting the swap at extreme ticks.
        if (tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK) {
            _supplyToAave(tokenToWithdraw, withdrawn); // don't strand the funds
            return;
        }

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            zeroForOne ? 0 : withdrawn,
            zeroForOne ? withdrawn : 0
        );
        if (liquidity == 0) {
            _supplyToAave(tokenToWithdraw, withdrawn); // don't strand the funds
            return;
        }

        // 2. Add output-side liquidity to the Uniswap V4 pool ahead of the price direction
        poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            new bytes(0)
        );

        // 3. Settle the newly added liquidity with the PoolManager
        //    Note: sync() must come BEFORE the transfer so settle() measures the increase.
        poolManager.sync(Currency.wrap(tokenToWithdraw));
        IERC20(tokenToWithdraw).transfer(address(poolManager), withdrawn);
        poolManager.settle();

        emit JITLiquidityAdded(key.toId(), tokenToWithdraw, withdrawn, liquidity);
    }

    /// @dev Supplies tokens to the lending protocol, approving it once per token.
    function _supplyToAave(address token, uint256 amount) internal {
        if (!isAaveApproved[token]) {
            IERC20(token).approve(address(aavePool), type(uint256).max);
            isAaveApproved[token] = true;
        }
        aavePool.supply(token, amount, address(this), 0);
    }

    /// @dev Packs (specified, unspecified) with the specified delta in the high 128 bits,
    ///      matching `BeforeSwapDeltaLibrary.getSpecifiedDelta/getUnspecifiedDelta`.
    function toBeforeSwapDelta(int128 deltaSpecified, int128 deltaUnspecified)
        internal
        pure
        returns (BeforeSwapDelta delta)
    {
        assembly {
            delta := or(shl(128, deltaSpecified), and(deltaUnspecified, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
        }
    }

    /// @notice Permissionless function to sweep idle liquidity from the AMM into the yield-generating protocol.
    /// @dev Only touches positions owned by this hook (salt 0). Anyone may trigger the rebalance.
    ///      Executes inside the PoolManager's unlock context (via unlockCallback below) because
    ///      modifyLiquidity/take revert outside of it.
    function sweepIdleLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint256 liquidityToRemove)
        external
    {
        poolManager.unlock(
            abi.encode(
                SweepCallbackData({
                    key: key,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityToRemove: liquidityToRemove
                })
            )
        );
    }

    struct SweepCallbackData {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint256 liquidityToRemove;
    }

    /// @notice Unlock callback for sweepIdleLiquidity: removes the hook-owned liquidity,
    ///         takes the withdrawn tokens, and supplies them to the lending protocol.
    /// @dev Only the PoolManager can invoke this, and only as a result of this hook
    ///      calling poolManager.unlock from sweepIdleLiquidity. The idle buffer is
    ///      enforced here: at most (10000 - idleBufferBips) of the position's current
    ///      liquidity is removed, so baseline reserves stay in the AMM.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "only PoolManager");
        SweepCallbackData memory d = abi.decode(data, (SweepCallbackData));

        (uint128 positionLiquidity,,) =
            poolManager.getPositionInfo(d.key.toId(), address(this), d.tickLower, d.tickUpper, bytes32(0));
        uint256 maxRemovable = uint256(positionLiquidity) * (10000 - idleBufferBips) / 10000;
        uint256 liquidityToRemove = d.liquidityToRemove > maxRemovable ? maxRemovable : d.liquidityToRemove;
        if (liquidityToRemove == 0) return "";

        // 1. Remove liquidity from Uniswap V4
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            d.key,
            ModifyLiquidityParams({
                tickLower: d.tickLower,
                tickUpper: d.tickUpper,
                liquidityDelta: -int256(liquidityToRemove),
                salt: bytes32(0)
            }),
            new bytes(0)
        );

        // 2. Take the withdrawn tokens from the PoolManager and supply to Aave
        uint256 amount0;
        uint256 amount1;
        if (delta.amount0() > 0) {
            address token0 = Currency.unwrap(d.key.currency0);
            amount0 = uint256(uint128(delta.amount0()));

            poolManager.take(d.key.currency0, address(this), amount0);
            _supplyToAave(token0, amount0);
        }

        if (delta.amount1() > 0) {
            address token1 = Currency.unwrap(d.key.currency1);
            amount1 = uint256(uint128(delta.amount1()));

            poolManager.take(d.key.currency1, address(this), amount1);
            _supplyToAave(token1, amount1);
        }

        emit IdleLiquiditySwept(d.key.toId(), amount0, amount1);
        return "";
    }
}
