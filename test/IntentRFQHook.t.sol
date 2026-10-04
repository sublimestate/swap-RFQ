// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IntentRFQHook} from "../src/IntentRFQHook.sol";
import {IAaveV3Pool} from "../src/interfaces/IAaveV3Pool.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/interfaces/IPoolManager.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

contract IntentRFQHookHarness is IntentRFQHook {
    constructor(IPoolManager _poolManager, address _lendingPool, address _l1PoolAddress)
        IntentRFQHook(_poolManager, _lendingPool, _l1PoolAddress)
    {}

    function verifySolverSignature(PoolKey calldata key, bool zeroForOne, SolverQuote memory quote)
        public
        returns (bool)
    {
        return super._verifySolverSignature(key, zeroForOne, quote);
    }
}

/// @notice Minimal mock of the Aave V3 pool: holds tokens and honors withdraw/supply.
contract MockAavePool is IAaveV3Pool {
    function supply(address asset, uint256 amount, address, uint16) external override {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        IERC20(asset).transfer(to, amount);
        return amount;
    }
}

import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract IntentRFQHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IntentRFQHookHarness public hook;
    MockAavePool public mockAavePool;
    address public mockL1Pool = address(0x456);

    uint256 solverPrivateKey = 0xA11CE;
    address solverAddress;

    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        solverAddress = vm.addr(solverPrivateKey);

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        mockAavePool = new MockAavePool();

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        (, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(IntentRFQHookHarness).creationCode,
            abi.encode(manager, address(mockAavePool), mockL1Pool)
        );

        hook = new IntentRFQHookHarness{salt: salt}(manager, address(mockAavePool), mockL1Pool);

        hook.setAuthorizedSolver(solverAddress, true);

        // Initialize a pool with the hook
        (poolKey, poolId) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _signQuote(
        uint256 pk,
        address solver,
        uint256 amountIn,
        uint256 amountOut,
        uint256 nonce,
        uint256 deadline,
        bool zeroForOne
    ) internal view returns (bytes memory) {
        bytes32 messageHash =
            keccak256(abi.encode(poolId, zeroForOne, solver, amountIn, amountOut, nonce, deadline));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSignedMessageHash);
        return abi.encodePacked(r, s, v);
    }

    function _makeQuote(
        uint256 amountIn,
        uint256 amountOut,
        uint256 nonce,
        uint256 deadline,
        bool zeroForOne,
        bytes memory signature
    ) internal view returns (IntentRFQHook.SolverQuote memory) {
        return IntentRFQHook.SolverQuote({
            solver: solverAddress,
            amountIn: amountIn,
            amountOut: amountOut,
            nonce: nonce,
            deadline: deadline,
            signature: signature
        });
    }

    /// @notice Adds liquidity directly through the modify-liquidity router.
    function _addLiquidity(int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1) internal {
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        IERC20(Currency.unwrap(currency0)).transfer(address(modifyLiquidityRouter), amount0);
        IERC20(Currency.unwrap(currency1)).transfer(address(modifyLiquidityRouter), amount1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)}),
            ""
        );
    }

    // -------------------------------------------------------------------------
    // Unit tests
    // -------------------------------------------------------------------------

    function test_Initialization() public view {
        assertEq(address(hook.aavePool()), address(mockAavePool));
        assertEq(hook.owner(), address(this));
    }

    function test_SetAuthorizedSolver() public {
        // Owner can set
        hook.setAuthorizedSolver(address(0x999), true);
        assertTrue(hook.isAuthorizedSolver(address(0x999)));

        // Non-owner cannot set
        vm.prank(address(0x111));
        vm.expectRevert();
        hook.setAuthorizedSolver(address(0x999), false);
    }

    function test_HookPermissions() public view {
        assertTrue(hook.getHookPermissions().beforeSwap);
        assertTrue(hook.getHookPermissions().beforeSwapReturnDelta);
        assertFalse(hook.getHookPermissions().afterSwap);
    }

    function testFuzz_ValidSignature(uint256 amountIn, uint256 amountOut) public {
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 100;

        bytes memory signature = _signQuote(solverPrivateKey, solverAddress, amountIn, amountOut, nonce, deadline, true);

        assertTrue(hook.verifySolverSignature(poolKey, true, _makeQuote(amountIn, amountOut, nonce, deadline, true, signature)));
        assertEq(hook.solverNonces(solverAddress), nonce + 1); // Nonce increments on success
    }

    function testFuzz_UnauthorizedSolver(uint256 amountIn, uint256 amountOut) public {
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 100;

        // Generate signature from unauthorized address
        uint256 badPk = 0xBADC0DE;
        address badSigner = vm.addr(badPk);

        bytes memory signature = _signQuote(badPk, badSigner, amountIn, amountOut, nonce, deadline, true);

        IntentRFQHook.SolverQuote memory quote = IntentRFQHook.SolverQuote({
            solver: badSigner,
            amountIn: amountIn,
            amountOut: amountOut,
            nonce: nonce,
            deadline: deadline,
            signature: signature
        });

        // verifySolverSignature returns false for unauthorized solvers
        assertFalse(hook.verifySolverSignature(poolKey, true, quote));

        // Nonce should NOT increment if the signature isn't validly matched to an authorized solver
        assertEq(hook.solverNonces(badSigner), 0);
    }

    function testFuzz_InvalidNonce(uint256 amountIn, uint256 amountOut, uint256 badNonce) public {
        vm.assume(badNonce != 0); // Correct nonce is 0
        uint256 deadline = block.timestamp + 100;

        bytes memory signature = _signQuote(solverPrivateKey, solverAddress, amountIn, amountOut, badNonce, deadline, true);

        // Invalid nonce no longer reverts; the swap simply falls back to the AMM.
        assertFalse(
            hook.verifySolverSignature(poolKey, true, _makeQuote(amountIn, amountOut, badNonce, deadline, true, signature))
        );
    }

    function testFuzz_ExpiredSignature(uint256 amountIn, uint256 amountOut) public {
        uint256 nonce = 0;
        uint256 deadline = block.timestamp - 1; // Expired

        bytes memory signature = _signQuote(solverPrivateKey, solverAddress, amountIn, amountOut, nonce, deadline, true);

        // Expired signatures no longer revert; the swap simply falls back to the AMM.
        assertFalse(
            hook.verifySolverSignature(poolKey, true, _makeQuote(amountIn, amountOut, nonce, deadline, true, signature))
        );
    }

    function test_QuoteBoundToPool() public {
        // A quote signed for a different pool must not verify for this pool.
        uint256 deadline = block.timestamp + 100;
        PoolId otherPoolId = PoolId.wrap(bytes32(uint256(12345)));
        bytes32 messageHash =
            keccak256(abi.encode(otherPoolId, true, solverAddress, 1 ether, 1 ether, 0, deadline));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(solverPrivateKey, MessageHashUtils.toEthSignedMessageHash(messageHash));

        IntentRFQHook.SolverQuote memory quote = _makeQuote(
            1 ether, 1 ether, 0, deadline, true, abi.encodePacked(r, s, v)
        );
        assertFalse(hook.verifySolverSignature(poolKey, true, quote));
    }

    // -------------------------------------------------------------------------
    // End-to-end tests
    // -------------------------------------------------------------------------

    /// @notice Full solver-takeover flow: the solver's quote beats the AMM spot price,
    ///         the hook takes over the swap, and the user receives exactly the quoted amount.
    ///         This is the regression test for the BeforeSwapDelta accounting.
    function test_EndToEnd_SolverFill() public {
        uint256 amountIn = 1 ether;
        uint256 amountOut = 1 ether; // == spot at 1:1; beats the AMM once fees are considered

        // Seed the pool with liquidity and fund the solver with output tokens.
        _addLiquidity(-60000, 60000, 100 ether, 100 ether);
        IERC20 token0 = IERC20(Currency.unwrap(currency0));
        IERC20 token1 = IERC20(Currency.unwrap(currency1));
        token1.transfer(solverAddress, 10 ether);
        vm.prank(solverAddress);
        token1.approve(address(hook), type(uint256).max);

        uint256 deadline = block.timestamp + 100;
        bytes memory signature = _signQuote(solverPrivateKey, solverAddress, amountIn, amountOut, 0, deadline, true);
        bytes memory hookData = abi.encode(_makeQuote(amountIn, amountOut, 0, deadline, true, signature));

        uint256 userT0Before = token0.balanceOf(address(this));
        uint256 userT1Before = token1.balanceOf(address(this));
        uint256 solverT0Before = token0.balanceOf(solverAddress);
        uint256 solverT1Before = token1.balanceOf(solverAddress);

        // Must not revert (previously: CurrencyNotSettled / doubled AMM swap).
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        // User paid exactly amountIn and received exactly the quoted amountOut (zero slippage).
        assertEq(token0.balanceOf(address(this)), userT0Before - amountIn, "user token0");
        assertEq(token1.balanceOf(address(this)), userT1Before + amountOut, "user token1");
        // Solver received the user's input and paid out the quote.
        assertEq(token0.balanceOf(solverAddress), solverT0Before + amountIn, "solver token0");
        assertEq(token1.balanceOf(solverAddress), solverT1Before - amountOut, "solver token1");
        // Nonce consumed.
        assertEq(hook.solverNonces(solverAddress), 1);
    }

    /// @notice Stale quotes fall back to the AMM instead of reverting the swap.
    function test_StaleQuoteFallsBackToAMM() public {
        _addLiquidity(-60000, 60000, 100 ether, 100 ether);

        // Build a quote with the wrong nonce (stale).
        uint256 deadline = block.timestamp + 100;
        bytes memory signature = _signQuote(solverPrivateKey, solverAddress, 1 ether, 1 ether, 999, deadline, true);
        bytes memory hookData = abi.encode(_makeQuote(1 ether, 1 ether, 999, deadline, true, signature));

        IERC20 token1 = IERC20(Currency.unwrap(currency1));

        // Fund the mock Aave pool BEFORE measuring (it needs output-side tokens for JIT).
        token1.transfer(address(mockAavePool), 10 ether);
        uint256 userT1Before = token1.balanceOf(address(this));

        // Swap succeeds via the AMM fallback (JIT path uses the mock Aave pool).
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        assertGt(token1.balanceOf(address(this)), userT1Before, "user received AMM output");
        assertEq(hook.solverNonces(solverAddress), 0, "stale quote must not consume nonce");
    }

    /// @notice AMM fallback path: with no solver quote, the hook JIT-sources output-side
    ///         liquidity from the lending protocol and the swap executes.
    function test_Fallback_JITClawback() public {
        _addLiquidity(-60000, 60000, 100 ether, 100 ether);

        // Fund the mock Aave pool with the OUTPUT token (token1 for a zeroForOne swap).
        IERC20 token1 = IERC20(Currency.unwrap(currency1));
        token1.transfer(address(mockAavePool), 10 ether);

        uint256 userT1Before = token1.balanceOf(address(this));

        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertGt(token1.balanceOf(address(this)), userT1Before, "user received output tokens");
    }

    /// @notice sweepIdleLiquidity recycles a hook-owned JIT position back into the
    ///         lending protocol. Regression test: the sweep must run inside the
    ///         PoolManager's unlock context (modifyLiquidity/take revert outside it).
    function test_SweepIdleLiquidity() public {
        _addLiquidity(-60000, 60000, 100 ether, 100 ether);

        IERC20 token1 = IERC20(Currency.unwrap(currency1));
        token1.transfer(address(mockAavePool), 10 ether);

        // Fallback swap creates the hook-owned JIT position (zeroForOne => token1-only,
        // range below the pre-swap tick; pool is fresh at 1:1 so tick is 0).
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Recompute the JIT range exactly like the hook does (pre-swap tick = 0).
        int24 spacing = poolKey.tickSpacing;
        int24 baseTick = 0;
        int24 tickLower = baseTick - 3 * spacing;
        int24 tickUpper = baseTick;
        (uint128 jitLiquidity,,) =
            manager.getPositionInfo(poolId, address(hook), tickLower, tickUpper, bytes32(0));
        assertGt(jitLiquidity, 0, "JIT position exists");

        uint256 aaveT1Before = token1.balanceOf(address(mockAavePool));

        // Standalone call (no unlock context) — this reverted before the fix.
        vm.expectEmit(true, false, false, false);
        emit IntentRFQHook.IdleLiquiditySwept(poolId, 0, 0);
        hook.sweepIdleLiquidity(poolKey, tickLower, tickUpper, jitLiquidity);

        // The idle buffer (10% default) stays in the AMM; the rest is recycled.
        (uint128 liqAfter,,) =
            manager.getPositionInfo(poolId, address(hook), tickLower, tickUpper, bytes32(0));
        uint256 expectedRemainder = jitLiquidity - (uint256(jitLiquidity) * 9000 / 10000);
        assertEq(liqAfter, expectedRemainder, "idle buffer remains in AMM");
        assertGt(token1.balanceOf(address(mockAavePool)), aaveT1Before, "Aave received swept tokens");
    }

    /// @notice Setting the buffer to zero allows a full sweep of the position.
    function test_SweepIdleLiquidity_ZeroBuffer() public {
        hook.setIdleBufferBips(0);
        _addLiquidity(-60000, 60000, 100 ether, 100 ether);

        IERC20 token1 = IERC20(Currency.unwrap(currency1));
        token1.transfer(address(mockAavePool), 10 ether);

        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        int24 spacing = poolKey.tickSpacing;
        int24 tickLower = -3 * spacing;
        int24 tickUpper = 0;
        (uint128 jitLiquidity,,) =
            manager.getPositionInfo(poolId, address(hook), tickLower, tickUpper, bytes32(0));
        assertGt(jitLiquidity, 0, "JIT position exists");

        hook.sweepIdleLiquidity(poolKey, tickLower, tickUpper, jitLiquidity);

        (uint128 liqAfter,,) =
            manager.getPositionInfo(poolId, address(hook), tickLower, tickUpper, bytes32(0));
        assertEq(liqAfter, 0, "JIT position fully removed with zero buffer");
    }

    /// @notice Only the owner can change the buffer, and it is capped at 50%.
    function test_SetIdleBufferBips() public {
        assertEq(hook.idleBufferBips(), 1000, "default 10%");

        hook.setIdleBufferBips(2500);
        assertEq(hook.idleBufferBips(), 2500, "owner can set");

        vm.expectRevert("buffer too high");
        hook.setIdleBufferBips(5001);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        hook.setIdleBufferBips(0);
    }

    /// @notice If the lending protocol cannot serve the JIT withdrawal (e.g. 100%
    ///         utilization), the swap still executes against the AMM — it is not bricked.
    function test_Fallback_SurvivesAaveIlliquidity() public {
        _addLiquidity(-60000, 60000, 100 ether, 100 ether);

        // Aave holds no token1: the mock's withdraw reverts (insufficient balance).
        // The JIT must degrade gracefully instead of reverting the user's swap.
        IERC20 token1 = IERC20(Currency.unwrap(currency1));
        assertEq(token1.balanceOf(address(mockAavePool)), 0, "Aave empty");

        uint256 userT0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 userT1Before = token1.balanceOf(address(this));

        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Swap executed via the AMM's own reserves (user paid input, got output).
        assertLt(IERC20(Currency.unwrap(currency0)).balanceOf(address(this)), userT0Before, "paid input");
        assertGt(token1.balanceOf(address(this)), userT1Before, "received output");

        // No hook-owned JIT position was created (JIT was skipped).
        int24 spacing = poolKey.tickSpacing;
        (uint128 jitLiquidity,,) =
            manager.getPositionInfo(poolId, address(hook), -3 * spacing, 0, bytes32(0));
        assertEq(jitLiquidity, 0, "no JIT position when Aave illiquid");
    }

    /// @notice simulateAMMSwap matches the real AMM execution exactly (no JIT here —
    ///         Aave is empty so the JIT is skipped and the swap is pure AMM).
    function test_SimulationMatchesAMM() public {
        _addLiquidity(-60000, 60000, 100 ether, 100 ether);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1 ether),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        (, uint256 simOut, bool exact) = hook.simulateAMMSwap(poolKey, params);
        assertTrue(exact, "simulation exact");

        IERC20 token1 = IERC20(Currency.unwrap(currency1));
        uint256 userT1Before = token1.balanceOf(address(this));
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), "");
        uint256 actualOut = token1.balanceOf(address(this)) - userT1Before;

        assertEq(simOut, actualOut, "simulation matches AMM output");
    }

    /// @notice Fuzz: the simulation matches the real AMM across swap sizes.
    function testFuzz_SimulationMatchesAMM(uint256 amountIn) public {
        amountIn = bound(amountIn, 0.01 ether, 50 ether);
        _addLiquidity(-60000, 60000, 100 ether, 100 ether);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        (, uint256 simOut, bool exact) = hook.simulateAMMSwap(poolKey, params);
        assertTrue(exact, "simulation exact");

        IERC20 token1 = IERC20(Currency.unwrap(currency1));
        uint256 userT1Before = token1.balanceOf(address(this));
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), "");
        assertEq(token1.balanceOf(address(this)) - userT1Before, simOut, "simulation matches AMM");
    }

    /// @notice The quote check uses the true AMM execution price (fees + impact), not the
    ///         marginal spot price. A quote between the true output and the spot estimate
    ///         is better for the user than the AMM — it must WIN the fill.
    function test_QuoteBeatsTrueAMMPrice_NotSpot() public {
        _addLiquidity(-60000, 60000, 100 ether, 100 ether);

        IERC20 token1 = IERC20(Currency.unwrap(currency1));
        token1.transfer(solverAddress, 100 ether);
        vm.prank(solverAddress);
        token1.approve(address(hook), type(uint256).max);

        uint256 amountIn = 10 ether;
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        (, uint256 ammOut, bool exact) = hook.simulateAMMSwap(poolKey, params);
        assertTrue(exact, "simulation exact");
        // 1:1 pool: the old spot check used amountIn as the bar. Fees + impact make
        // the true output strictly lower.
        assertLt(ammOut, amountIn, "true output below spot");

        // Quote strictly between the true AMM output and spot: the old marginal-price
        // check would reject this (quote < spot); the true-price check must accept it.
        uint256 quoteOut = (ammOut + amountIn) / 2;
        assertGt(quoteOut, ammOut, "quote beats AMM");
        assertLt(quoteOut, amountIn, "quote below spot");

        uint256 deadline = block.timestamp + 100;
        bytes memory signature = _signQuote(solverPrivateKey, solverAddress, amountIn, quoteOut, 0, deadline, true);
        bytes memory hookData = abi.encode(_makeQuote(amountIn, quoteOut, 0, deadline, true, signature));

        uint256 userT1Before = token1.balanceOf(address(this));
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), hookData);
        assertEq(token1.balanceOf(address(this)), userT1Before + quoteOut, "solver fill at quoted price");
    }

    /// @notice Exact-output quotes are checked against the AMM's required INPUT:
    ///         the solver must charge at most what the AMM would demand.
    function test_QuoteExactOutput_BeatsAMMInput() public {
        _addLiquidity(-60000, 60000, 100 ether, 100 ether);

        IERC20 token1 = IERC20(Currency.unwrap(currency1));
        token1.transfer(solverAddress, 100 ether);
        vm.prank(solverAddress);
        token1.approve(address(hook), type(uint256).max);

        uint256 amountOut = 1 ether;
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: int256(amountOut),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        (uint256 ammIn,, bool exact) = hook.simulateAMMSwap(poolKey, params);
        assertTrue(exact, "simulation exact");
        assertGt(ammIn, amountOut, "AMM charges fee + impact over par");

        // Solver charges slightly less than the AMM would: must win.
        uint256 quoteIn = ammIn - 0.001 ether;
        uint256 deadline = block.timestamp + 100;
        bytes memory signature = _signQuote(solverPrivateKey, solverAddress, quoteIn, amountOut, 0, deadline, true);
        bytes memory hookData = abi.encode(_makeQuote(quoteIn, amountOut, 0, deadline, true, signature));

        IERC20 token0 = IERC20(Currency.unwrap(currency0));
        uint256 userT0Before = token0.balanceOf(address(this));
        uint256 userT1Before = token1.balanceOf(address(this));
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), hookData);

        assertEq(token1.balanceOf(address(this)), userT1Before + amountOut, "exact output delivered");
        assertEq(userT0Before - token0.balanceOf(address(this)), quoteIn, "paid quoted input");
    }
}
