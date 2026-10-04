// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/src/interfaces/IPoolManager.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IntentRFQHook} from "../src/IntentRFQHook.sol";
import {MockAavePool} from "./MockAavePool.sol";

/// @notice Minimal CREATE2 factory for the hook. Forge 1.8.x forbids `new X{salt}`
///         directly inside script contracts (the script address is ephemeral), so the
///         hook is deployed via this intermediate contract instead.
/// @dev Takes the init code as calldata so this factory stays well under the
///      contract size limit.
contract HookDeployer {
    function deployHook(bytes32 salt, bytes memory initCode, address owner)
        external
        returns (IntentRFQHook hook)
    {
        assembly {
            hook := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(address(hook) != address(0), "create2 failed");
        hook.transferOwnership(owner);
    }
}

/// @notice Deploys the full IntentRFQ demo stack on a v4 testnet:
///         mock tokens, mock Aave pool, the hook (via HookMiner), test routers,
///         initializes the pool, seeds liquidity, funds the solver and seeds Aave.
///         Writes everything to deployments/unichain-sepolia.json.
/// @dev Requires env vars: DEPLOYER_KEY, SOLVER_KEY.
contract TestnetDeploy is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    IPoolManager manager;
    uint160 constant SQRT_PRICE_1_1 = (uint160(1) << 96);

    struct Deploy {
        address deployer;
        address solver;
        uint256 deployerKey;
        uint256 solverKey;
        MockAavePool mockAave;
        PoolSwapTest swapRouter;
        PoolModifyLiquidityTest liqRouter;
        IntentRFQHook hook;
        IERC20 token0;
        IERC20 token1;
        PoolKey key;
        PoolId poolId;
    }

    function run() external {
        Deploy memory d;
        d.deployerKey = vm.envUint("DEPLOYER_KEY");
        d.solverKey = vm.envUint("SOLVER_KEY");
        d.deployer = vm.addr(d.deployerKey);
        d.solver = vm.addr(d.solverKey);
        manager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        console.log("PoolManager:", address(manager));
        console.log("Deployer:", d.deployer);
        console.log("Solver:  ", d.solver);

        vm.startBroadcast(d.deployerKey);
        _deployPrimitives(d);
        _deployHook(d);
        _initPool(d);
        _seedLiquidity(d);
        _fundParticipants(d);
        vm.stopBroadcast();

        vm.startBroadcast(d.solverKey);
        d.token1.approve(address(d.hook), type(uint256).max);
        vm.stopBroadcast();

        _writeDeployment(d);
    }

    function _deployPrimitives(Deploy memory d) internal {
        MockERC20 tokenA = new MockERC20("Test Token A", "TTA", 18);
        MockERC20 tokenB = new MockERC20("Test Token B", "TTB", 18);
        tokenA.mint(d.deployer, 1_000_000 ether);
        tokenB.mint(d.deployer, 1_000_000 ether);
        (d.token0, d.token1) = address(tokenA) < address(tokenB)
            ? (IERC20(address(tokenA)), IERC20(address(tokenB)))
            : (IERC20(address(tokenB)), IERC20(address(tokenA)));
        console.log("Token0:", address(d.token0));
        console.log("Token1:", address(d.token1));

        d.mockAave = new MockAavePool();
        console.log("MockAave:", address(d.mockAave));

        d.swapRouter = new PoolSwapTest(manager);
        d.liqRouter = new PoolModifyLiquidityTest(manager);
    }

    function _deployHook(Deploy memory d) internal {
        // Deploy the CREATE2 factory first (plain CREATE from the deployer EOA).
        HookDeployer hookDeployer = new HookDeployer();
        console.log("HookDeployer:", address(hookDeployer));

        // Mine the salt against the factory's address, then deploy through it.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory ctorArgs = abi.encode(manager, address(d.mockAave), address(0));
        bytes memory initCode = abi.encodePacked(type(IntentRFQHook).creationCode, ctorArgs);
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(hookDeployer), flags, type(IntentRFQHook).creationCode, ctorArgs);
        d.hook = hookDeployer.deployHook(salt, initCode, d.deployer);
        require(address(d.hook) == expectedHook, "hook address mismatch");
        console.log("Hook:        ", address(d.hook));

        d.hook.setAuthorizedSolver(d.solver, true);
    }

    function _initPool(Deploy memory d) internal {
        d.key = PoolKey({
            currency0: Currency.wrap(address(d.token0)),
            currency1: Currency.wrap(address(d.token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: d.hook
        });
        manager.initialize(d.key, SQRT_PRICE_1_1);
        d.poolId = d.key.toId();
        console.log("PoolId: ");
        console.logBytes32(PoolId.unwrap(d.poolId));
    }

    function _seedLiquidity(Deploy memory d) internal {
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(-60000),
            TickMath.getSqrtPriceAtTick(60000),
            100_000 ether,
            100_000 ether
        );
        d.token0.approve(address(d.liqRouter), 100_000 ether);
        d.token1.approve(address(d.liqRouter), 100_000 ether);
        d.liqRouter.modifyLiquidity(
            d.key,
            ModifyLiquidityParams({
                tickLower: -60000,
                tickUpper: 60000,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        console.log("Liquidity seeded, L =", liquidity);
    }

    function _fundParticipants(Deploy memory d) internal {
        // Seed the mock Aave pool with the OUTPUT token (token1) so the JIT
        // clawback has something to pull on fallback swaps.
        d.token1.transfer(address(d.mockAave), 50_000 ether);
        // Fund the solver with output tokens so it can fill quotes.
        d.token1.transfer(d.solver, 10_000 ether);
        // Fund the solver with gas for its approval transaction below.
        (bool ok,) = d.solver.call{value: 0.005 ether}("");
        require(ok, "solver gas funding failed");
    }

    function _writeDeployment(Deploy memory d) internal {
        string memory obj = "deployment";
        vm.serializeAddress(obj, "hook", address(d.hook));
        vm.serializeAddress(obj, "token0", address(d.token0));
        vm.serializeAddress(obj, "token1", address(d.token1));
        vm.serializeAddress(obj, "mockAave", address(d.mockAave));
        vm.serializeAddress(obj, "swapRouter", address(d.swapRouter));
        vm.serializeAddress(obj, "liqRouter", address(d.liqRouter));
        vm.serializeAddress(obj, "solver", d.solver);
        vm.serializeAddress(obj, "deployer", d.deployer);
        vm.serializeBytes32(obj, "poolId", PoolId.unwrap(d.poolId));
        vm.serializeUint(obj, "fee", 3000);
        vm.serializeUint(obj, "tickSpacing", 60);
        string memory finalJson = vm.serializeUint(obj, "chainId", block.chainid);
        string memory fileName = block.chainid == 84532
            ? "deployments/base-sepolia.json"
            : "deployments/unichain-sepolia.json";
        vm.writeFile(fileName, finalJson);
        console.log("Deployment written to", fileName);
    }
}
