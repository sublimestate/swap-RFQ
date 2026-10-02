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
import {IAaveV3Pool} from "./interfaces/IAaveV3Pool.sol";

contract IntentRFQHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    IAaveV3Pool public immutable aavePool;
    
    mapping(address => bool) public isAuthorizedSolver;
    mapping(address => uint256) public solverNonces;
    mapping(address => bool) public isAaveApproved; // Tracks infinite approvals to save gas
    
    // Scroll L1SLOAD precompile address mock
    address public constant L1_SLOAD_PRECOMPILE = 0x0000000000000000000000000000000000000101;
    
    address public immutable l1PoolAddress;
    uint256 public constant MAX_SQRT_PRICE_DEVIATION_BIPS = 25; // ~0.5% price deviation
    
    error InvalidSignature();
    error LVRAttackDetected();
    error SignatureExpired();
    error InvalidNonce();

    constructor(IPoolManager _poolManager, address _aavePool, address _l1PoolAddress) BaseHook(_poolManager) {
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

    // This data would be provided by the off-chain solver and signed
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
        // 1. Unpack hookData
        if (hookData.length > 0) {
            SolverQuote memory quote = abi.decode(hookData, (SolverQuote));
            
            // 2. Verify solver signature (simplified for v1.0)
            bool isValid = _verifySolverSignature(quote);
            
            if (isValid) {
                // 3. Price comparison: Ensure solver price is better than AMM
                // (In a full implementation, we'd compare against the slot0 current price)
                
                // 4. Execution: Facilitate direct settlement
                // Execute transfers directly between user and solver
                _settleWithSolver(key, params, quote);

                // Return NoOp: instructed the pool that swap is fully handled
                // Calculate precise custom delta matching the swap
                int256 amount0 = params.zeroForOne ? params.amountSpecified : -int256(quote.amountOut);
                int256 amount1 = params.zeroForOne ? -int256(quote.amountOut) : params.amountSpecified;
                
                BeforeSwapDelta customDelta = toBeforeSwapDelta(int128(amount0), int128(amount1));
                
                return (BaseHook.beforeSwap.selector, customDelta, 0);
            }
        }

        // 5. Fallback: Standard AMM execution
        // Check LVR protection first
        _checkLVRProtection(key);
        
        // JIT Clawback: withdraw needed liquidity from Lending Protocol
        _jitClawback(key, params);
        
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // TODO(Optimization): Replace OpenZeppelin ECDSA with raw inline assembly `ecrecover`
    // to reduce gas overhead by ~12,000 units on the hot path since this executes pre-swap.
    function _verifySolverSignature(SolverQuote memory quote) internal returns (bool) {
        if (block.timestamp > quote.deadline) revert SignatureExpired();
        if (quote.nonce != solverNonces[quote.solver]) revert InvalidNonce();

        // Increment nonce
        solverNonces[quote.solver]++;

        // Construct the message hash
        bytes32 messageHash = keccak256(abi.encodePacked(quote.solver, quote.amountIn, quote.amountOut, quote.nonce, quote.deadline));
        
        // Recover the signer from the Ethereum signed message format
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        address recoveredSigner = ECDSA.recover(ethSignedMessageHash, quote.signature);
        
        // Verify the recovered signer matches the solver and is authorized
        return recoveredSigner == quote.solver && isAuthorizedSolver[quote.solver];
    }

    function _settleWithSolver(PoolKey calldata key, SwapParams calldata params, SolverQuote memory quote) internal {
        // Determine currencies
        Currency currencyIn = params.zeroForOne ? key.currency0 : key.currency1;
        Currency currencyOut = params.zeroForOne ? key.currency1 : key.currency0;

        // If amountSpecified is negative, it's exactIn (user pays amountSpecified).
        uint256 amountIn = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : quote.amountIn;
        uint256 amountOut = quote.amountOut;

        // 1. Hook takes `amountIn` of currencyIn from PoolManager and gives it to the Solver.
        // Since the PoolManager might not have the ERC20 tokens yet (as the router pays after swap),
        // we mint ERC6909 claims to the solver which they can burn later.
        poolManager.mint(quote.solver, currencyIn.toId(), amountIn);

        // 2. Hook pulls `amountOut` of currencyOut from Solver to PoolManager.
        // The solver must have approved this hook contract.
        // We use IERC20 to transfer the tokens.
        if (Currency.unwrap(currencyOut) != address(0)) {
            IERC20(Currency.unwrap(currencyOut)).transferFrom(quote.solver, address(poolManager), amountOut);
        } else {
            // For native ETH, solver would need to send ETH directly to the PoolManager.
            // Simplified for v1.0.
        }

        // 3. Settle the currencyOut with the PoolManager to clear the hook's debit.
        poolManager.sync(currencyOut);
        poolManager.settle();
    }

    function _checkLVRProtection(PoolKey calldata key) internal view {
        if (l1PoolAddress == address(0)) return;

        // Get the L2 AMM price
        (uint160 sqrtPriceX96L2, , , ) = poolManager.getSlot0(key.toId());

        // Read L1 spot price via L1SLOAD precompile (mocked call)
        if (L1_SLOAD_PRECOMPILE.code.length > 0) {
            (bool success, bytes memory data) = L1_SLOAD_PRECOMPILE.staticcall(
                abi.encodePacked(l1PoolAddress, uint256(0))
            );

            if (success && data.length >= 32) {
                uint256 slot0Data = abi.decode(data, (uint256));
                // sqrtPriceX96 is the lowest 160 bits of Slot0
                uint160 sqrtPriceX96L1 = uint160(slot0Data & 0x00FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF);
                
                // Check discrepancy
                if (sqrtPriceX96L1 > 0 && sqrtPriceX96L2 > 0) {
                    uint256 diff = sqrtPriceX96L1 > sqrtPriceX96L2 
                        ? sqrtPriceX96L1 - sqrtPriceX96L2 
                        : sqrtPriceX96L2 - sqrtPriceX96L1;
                    
                    uint256 deviationBips = (diff * 10000) / sqrtPriceX96L2;
                    
                    if (deviationBips > MAX_SQRT_PRICE_DEVIATION_BIPS) {
                        revert LVRAttackDetected();
                    }
                }
            }
        }
    }

    int24 public constant CLAWBACK_TICK_LOWER = -60;
    int24 public constant CLAWBACK_TICK_UPPER = 60;

    function _jitClawback(PoolKey calldata key, SwapParams calldata params) internal {
        // Calculate exact liquidity required for fallback
        uint256 requiredAmount = uint256(params.amountSpecified > 0 ? params.amountSpecified : -params.amountSpecified);
        
        // Identify which token the AMM needs for the user's exact input/output
        address tokenToWithdraw = params.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        
        if (tokenToWithdraw != address(0)) {
            // 1. Just-In-Time withdrawal from yield-generating protocol
            aavePool.withdraw(tokenToWithdraw, requiredAmount, address(this));
            
            // 2. Add liquidity to the Uniswap V4 Pool dynamically
            // (Using requiredAmount as liquidityDelta for mock simplicity)
            poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: CLAWBACK_TICK_LOWER,
                    tickUpper: CLAWBACK_TICK_UPPER,
                    liquidityDelta: int256(requiredAmount),
                    salt: bytes32(0)
                }),
                new bytes(0)
            );

            // 3. Settle the newly added liquidity with the PoolManager
            poolManager.sync(Currency.wrap(tokenToWithdraw));
            IERC20(tokenToWithdraw).transfer(address(poolManager), requiredAmount);
            poolManager.settle();
        }
    }

    // Helper from v4-core
    function toBeforeSwapDelta(int128 deltaUnspecified, int128 deltaSpecified) internal pure returns (BeforeSwapDelta delta) {
        assembly {
            delta := or(shl(128, deltaUnspecified), and(deltaSpecified, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
        }
    }

    /// @notice Permissionless function to sweep idle liquidity from the AMM into the yield-generating protocol
    function sweepIdleLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint256 liquidityToRemove) external {
        // 1. Remove liquidity from Uniswap V4
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(liquidityToRemove),
                salt: bytes32(0)
            }),
            new bytes(0)
        );

        // 2. Take the withdrawn tokens from the PoolManager and supply to Aave
        if (delta.amount0() > 0) {
            address token0 = Currency.unwrap(key.currency0);
            uint256 amount0 = uint256(uint128(delta.amount0()));
            
            poolManager.take(key.currency0, address(this), amount0);
            
            if (!isAaveApproved[token0]) {
                IERC20(token0).approve(address(aavePool), type(uint256).max);
                isAaveApproved[token0] = true;
            }
            aavePool.supply(token0, amount0, address(this), 0);
        }

        if (delta.amount1() > 0) {
            address token1 = Currency.unwrap(key.currency1);
            uint256 amount1 = uint256(uint128(delta.amount1()));
            
            poolManager.take(key.currency1, address(this), amount1);
            
            if (!isAaveApproved[token1]) {
                IERC20(token1).approve(address(aavePool), type(uint256).max);
                isAaveApproved[token1] = true;
            }
            aavePool.supply(token1, amount1, address(this), 0);
        }
    }
}
