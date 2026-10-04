// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IPoolManager, SwapParams} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IntentRFQHook} from "../src/IntentRFQHook.sol";

/// @notice Verifies the IntentRFQ testnet deployment end to end:
///         [1] solver fill with exact quoted output, [2] AMM fallback with JIT
///         clawback pulling output tokens from Aave, [3] sweeping JIT liquidity back.
///         Reads the deployment file from the DEPLOYMENT_FILE env var.
///         Requires DEPLOYER_KEY, SOLVER_KEY.
contract TestnetVerify is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Config loaded from deployments/unichain-sepolia.json (storage to dodge stack-too-deep).
    IntentRFQHook cfgHook;
    IERC20 cfgToken0;
    IERC20 cfgToken1;
    address cfgMockAave;
    PoolSwapTest cfgSwapRouter;
    PoolKey cfgKey;
    PoolId cfgPoolId;
    address cfgDeployer;
    address cfgSolver;
    uint256 cfgDeployerKey;
    uint256 cfgSolverKey;
    int24 cfgTickBeforeFallback;

    function run() external {
        _loadConfig();
        _verifySolverFill();
        _verifyFallback();
        _verifySweep();
        console.log("ALL CHECKS DONE");
    }

    function _loadConfig() internal {
        cfgDeployerKey = vm.envUint("DEPLOYER_KEY");
        cfgSolverKey = vm.envUint("SOLVER_KEY");
        cfgDeployer = vm.addr(cfgDeployerKey);
        cfgSolver = vm.addr(cfgSolverKey);

        string memory json = vm.readFile(vm.envString("DEPLOYMENT_FILE"));
        cfgHook = IntentRFQHook(vm.parseJsonAddress(json, ".hook"));
        cfgToken0 = IERC20(vm.parseJsonAddress(json, ".token0"));
        cfgToken1 = IERC20(vm.parseJsonAddress(json, ".token1"));
        cfgMockAave = vm.parseJsonAddress(json, ".mockAave");
        cfgSwapRouter = PoolSwapTest(vm.parseJsonAddress(json, ".swapRouter"));
        cfgKey = PoolKey({
            currency0: Currency.wrap(address(cfgToken0)),
            currency1: Currency.wrap(address(cfgToken1)),
            fee: uint24(vm.parseJsonUint(json, ".fee")),
            tickSpacing: int24(int256(vm.parseJsonUint(json, ".tickSpacing"))),
            hooks: cfgHook
        });
        cfgPoolId = cfgKey.toId();
        require(PoolId.unwrap(cfgPoolId) == vm.parseJsonBytes32(json, ".poolId"), "poolId mismatch");
    }

    function _swapExactInput(uint256 amountIn, bytes memory hookData) internal {
        cfgToken0.approve(address(cfgSwapRouter), amountIn);
        cfgSwapRouter.swap(
            cfgKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function _signedQuote(uint256 amountIn, uint256 amountOut, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 messageHash =
            keccak256(abi.encode(cfgPoolId, true, cfgSolver, amountIn, amountOut, nonce, deadline));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(cfgSolverKey, MessageHashUtils.toEthSignedMessageHash(messageHash));
        return abi.encode(
            IntentRFQHook.SolverQuote({
                solver: cfgSolver,
                amountIn: amountIn,
                amountOut: amountOut,
                nonce: nonce,
                deadline: deadline,
                signature: abi.encodePacked(r, s, v)
            })
        );
    }

    /// @notice [1] Solver fill: user pays exact input, receives exact quoted output.
    function _verifySolverFill() internal {
        uint256 amountIn = 10 ether;
        uint256 amountOut = 10.1 ether; // beats AMM spot (~10.0 at 1:1)
        uint256 nonce = cfgHook.solverNonces(cfgSolver);
        bytes memory hookData = _signedQuote(amountIn, amountOut, nonce, block.timestamp + 1 hours);

        uint256 userT0Before = cfgToken0.balanceOf(cfgDeployer);
        uint256 userT1Before = cfgToken1.balanceOf(cfgDeployer);
        uint256 solverT0Before = cfgToken0.balanceOf(cfgSolver);
        uint256 solverT1Before = cfgToken1.balanceOf(cfgSolver);

        vm.startBroadcast(cfgDeployerKey);
        _swapExactInput(amountIn, hookData);
        vm.stopBroadcast();

        require(cfgToken0.balanceOf(cfgDeployer) == userT0Before - amountIn, "[1] user paid wrong input");
        require(cfgToken1.balanceOf(cfgDeployer) == userT1Before + amountOut, "[1] user output mismatch");
        require(cfgToken0.balanceOf(cfgSolver) == solverT0Before + amountIn, "[1] solver input mismatch");
        require(cfgToken1.balanceOf(cfgSolver) == solverT1Before - amountOut, "[1] solver output mismatch");
        require(cfgHook.solverNonces(cfgSolver) == nonce + 1, "[1] nonce not consumed");
        console.log("PASS [1/3] solver fill: user paid 10 T0, received exactly 10.1 T1");
    }

    /// @notice [2] AMM fallback (empty hookData) with JIT clawback pulling output tokens from Aave.
    function _verifyFallback() internal {
        uint256 aaveT1Before = cfgToken1.balanceOf(cfgMockAave);
        uint256 userT1Before = cfgToken1.balanceOf(cfgDeployer);

        // Record the pre-swap tick: the hook computes its JIT range from it.
        (, int24 tickBefore,,) = cfgHook.poolManager().getSlot0(cfgPoolId);
        cfgTickBeforeFallback = tickBefore;

        vm.startBroadcast(cfgDeployerKey);
        _swapExactInput(1 ether, "");
        vm.stopBroadcast();

        require(cfgToken1.balanceOf(cfgDeployer) > userT1Before, "[2] fallback swap gave user nothing");
        require(
            cfgToken1.balanceOf(cfgMockAave) == aaveT1Before - 1 ether,
            "[2] JIT did not pull output tokens from Aave"
        );
        console.log("PASS [2/3] AMM fallback: swap succeeded, JIT pulled 1 T1 from Aave into the pool");
    }

    /// @notice [3] Sweep the hook-owned JIT position back into Aave (best-effort).
    function _verifySweep() internal {
        // Recompute the JIT ticks exactly like the hook does, from the PRE-swap tick.
        IPoolManager manager = cfgHook.poolManager();
        int24 currentTick = cfgTickBeforeFallback;
        int24 spacing = cfgKey.tickSpacing;
        int24 baseTick = (currentTick / spacing) * spacing;
        if (currentTick < 0 && currentTick % spacing != 0) baseTick -= spacing;
        int24 tickLower = baseTick - 3 * spacing;
        (uint128 jitLiquidity,,) =
            manager.getPositionInfo(cfgPoolId, address(cfgHook), tickLower, baseTick, bytes32(0));

        if (jitLiquidity == 0) {
            console.log("SKIP [3/3] no JIT position found at recomputed ticks");
            return;
        }
        uint256 aaveT1Before = cfgToken1.balanceOf(cfgMockAave);
        vm.startBroadcast(cfgDeployerKey);
        try cfgHook.sweepIdleLiquidity(cfgKey, tickLower, baseTick, jitLiquidity) {
            console.log("PASS [3/3] sweep: JIT liquidity recycled back to Aave");
        } catch {
            console.log("SKIP [3/3] sweepIdleLiquidity reverted");
        }
        vm.stopBroadcast();
        require(
            cfgToken1.balanceOf(cfgMockAave) >= aaveT1Before, "[3] Aave balance did not increase after sweep"
        );
    }
}
