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
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
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

        // The solver must beat the AMM spot price. Note: this compares against the
        // marginal spot price and ignores price impact/fees (see roadmap: slippage handling).
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        uint256 expectedOutAMM;
        if (params.zeroForOne) {
            // price = token1/token0 = (sqrtPriceX96^2) / 2^192
            expectedOutAMM = FullMath.mulDiv(quote.amountIn, priceX96, 1 << 96);
        } else {
            expectedOutAMM = FullMath.mulDiv(quote.amountIn, 1 << 96, priceX96);
        }

        return quote.amountOut >= expectedOutAMM;
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
    ///      Best-effort: never bricks the user's swap if JIT can't be placed.
    function _jitClawback(PoolKey calldata key, SwapParams calldata params) internal {
        // Calculate exact token amount required for the fallback swap
        uint256 requiredAmount = uint256(params.amountSpecified > 0 ? params.amountSpecified : -params.amountSpecified);

        // JIT liquidity must deepen the OUTPUT side of the swap — that is what determines
        // the execution price. (Withdrawing the input token would not improve the fill.)
        bool zeroForOne = params.zeroForOne;
        address tokenToWithdraw = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        if (tokenToWithdraw == address(0)) return;

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
        if (tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK) return;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            zeroForOne ? 0 : requiredAmount,
            zeroForOne ? requiredAmount : 0
        );
        if (liquidity == 0) return;

        // 1. Just-in-time withdrawal from the yield-generating protocol
        aavePool.withdraw(tokenToWithdraw, requiredAmount, address(this));

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
        IERC20(tokenToWithdraw).transfer(address(poolManager), requiredAmount);
        poolManager.settle();

        emit JITLiquidityAdded(key.toId(), tokenToWithdraw, requiredAmount, liquidity);
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
    ///      calling poolManager.unlock from sweepIdleLiquidity.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "only PoolManager");
        SweepCallbackData memory d = abi.decode(data, (SweepCallbackData));

        // 1. Remove liquidity from Uniswap V4
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            d.key,
            ModifyLiquidityParams({
                tickLower: d.tickLower,
                tickUpper: d.tickUpper,
                liquidityDelta: -int256(d.liquidityToRemove),
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

            if (!isAaveApproved[token0]) {
                IERC20(token0).approve(address(aavePool), type(uint256).max);
                isAaveApproved[token0] = true;
            }
            aavePool.supply(token0, amount0, address(this), 0);
        }

        if (delta.amount1() > 0) {
            address token1 = Currency.unwrap(d.key.currency1);
            amount1 = uint256(uint128(delta.amount1()));

            poolManager.take(d.key.currency1, address(this), amount1);

            if (!isAaveApproved[token1]) {
                IERC20(token1).approve(address(aavePool), type(uint256).max);
                isAaveApproved[token1] = true;
            }
            aavePool.supply(token1, amount1, address(this), 0);
        }

        emit IdleLiquiditySwept(d.key.toId(), amount0, amount1);
        return "";
    }
}
