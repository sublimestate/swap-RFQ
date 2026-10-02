// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IntentRFQHook} from "../src/IntentRFQHook.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract IntentRFQHookHarness is IntentRFQHook {
    constructor(IPoolManager _poolManager, address _lendingPool, address _l1PoolAddress) 
        IntentRFQHook(_poolManager, _lendingPool, _l1PoolAddress) {}

    function verifySolverSignature(SolverQuote memory quote) public returns (bool) {
        return super._verifySolverSignature(quote);
    }
    
    function setAuthorizedSolver(address solver, bool auth) public {
        isAuthorizedSolver[solver] = auth;
    }
}

import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract IntentRFQHookTest is Test, Deployers {
    IntentRFQHookHarness public hook;
    address public mockAavePool = address(0x123);
    address public mockL1Pool = address(0x456);

    uint256 solverPrivateKey = 0xA11CE;
    address solverAddress;

    function setUp() public {
        solverAddress = vm.addr(solverPrivateKey);
        
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(IntentRFQHookHarness).creationCode,
            abi.encode(manager, mockAavePool, mockL1Pool)
        );
        
        hook = new IntentRFQHookHarness{salt: salt}(manager, mockAavePool, mockL1Pool);
        
        hook.setAuthorizedSolver(solverAddress, true);
    }

    function test_Initialization() public view {
        assertEq(address(hook.aavePool()), mockAavePool);
    }

    function test_HookPermissions() public view {
        assertTrue(hook.getHookPermissions().beforeSwap);
        assertTrue(hook.getHookPermissions().beforeSwapReturnDelta);
        assertFalse(hook.getHookPermissions().afterSwap);
    }

    function testFuzz_ValidSignature(uint256 amountIn, uint256 amountOut) public {
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 100;
        
        bytes32 messageHash = keccak256(abi.encodePacked(solverAddress, amountIn, amountOut, nonce, deadline));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(solverPrivateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        IntentRFQHook.SolverQuote memory quote = IntentRFQHook.SolverQuote({
            solver: solverAddress,
            amountIn: amountIn,
            amountOut: amountOut,
            nonce: nonce,
            deadline: deadline,
            signature: signature
        });

        assertTrue(hook.verifySolverSignature(quote));
    }

    function testFuzz_InvalidNonce(uint256 amountIn, uint256 amountOut, uint256 badNonce) public {
        vm.assume(badNonce != 0); // Correct nonce is 0
        uint256 deadline = block.timestamp + 100;
        
        bytes32 messageHash = keccak256(abi.encodePacked(solverAddress, amountIn, amountOut, badNonce, deadline));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(solverPrivateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        IntentRFQHook.SolverQuote memory quote = IntentRFQHook.SolverQuote({
            solver: solverAddress,
            amountIn: amountIn,
            amountOut: amountOut,
            nonce: badNonce,
            deadline: deadline,
            signature: signature
        });

        vm.expectRevert(IntentRFQHook.InvalidNonce.selector);
        hook.verifySolverSignature(quote);
    }

    function testFuzz_ExpiredSignature(uint256 amountIn, uint256 amountOut) public {
        uint256 nonce = 0;
        uint256 deadline = block.timestamp - 1; // Expired
        
        bytes32 messageHash = keccak256(abi.encodePacked(solverAddress, amountIn, amountOut, nonce, deadline));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(solverPrivateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        IntentRFQHook.SolverQuote memory quote = IntentRFQHook.SolverQuote({
            solver: solverAddress,
            amountIn: amountIn,
            amountOut: amountOut,
            nonce: nonce,
            deadline: deadline,
            signature: signature
        });

        vm.expectRevert(IntentRFQHook.SignatureExpired.selector);
        hook.verifySolverSignature(quote);
    }
}
