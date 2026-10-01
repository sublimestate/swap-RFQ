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

// Mock interfaces for Aave/Spark lending protocol for JIT Clawback
interface ILendingPool {
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

contract IntentRFQHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    ILendingPool public immutable lendingPool;
    
    mapping(address => bool) public isAuthorizedSolver;
    
    // Scroll L1SLOAD precompile address mock
    address public constant L1_SLOAD_PRECOMPILE = 0x0000000000000000000000000000000000000101;
    
    address public immutable l1PoolAddress;
    uint256 public constant MAX_SQRT_PRICE_DEVIATION_BIPS = 25; // ~0.5% price deviation
    
    error InvalidSignature();
    error LVRAttackDetected();

    constructor(IPoolManager _poolManager, address _lendingPool, address _l1PoolAddress) BaseHook(_poolManager) {
        lendingPool = ILendingPool(_lendingPool);
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

    function _verifySolverSignature(SolverQuote memory quote) internal view returns (bool) {
        // Construct the message hash
        bytes32 messageHash = keccak256(abi.encodePacked(quote.solver, quote.amountIn, quote.amountOut));
        
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
            lendingPool.withdraw(tokenToWithdraw, requiredAmount, address(this));
            
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
}
