// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IntentRFQHook} from "../src/IntentRFQHook.sol";

contract DeployHookScript is Script {
    function run() external {
        // Load configuration from environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address poolManagerAddress = vm.envAddress("POOL_MANAGER");
        address aavePoolAddress = vm.envAddress("AAVE_V3_POOL");
        address l1PoolAddress = vm.envAddress("L1_POOL");

        IPoolManager manager = IPoolManager(poolManagerAddress);

        // Required flags for IntentRFQHook
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        // Prepare constructor arguments
        bytes memory constructorArgs = abi.encode(manager, aavePoolAddress, l1PoolAddress);

        address deployerAddress = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployerAddress);
        console.log("Mining hook address...");

        // HookMiner mines a salt that produces an address with the required flags
        (address expectedAddress, bytes32 salt) = HookMiner.find(
            deployerAddress,
            flags,
            type(IntentRFQHook).creationCode,
            constructorArgs
        );

        console.log("Mined salt:", vm.toString(salt));
        console.log("Expected Hook Address:", expectedAddress);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy the hook using CREATE2 with the mined salt
        IntentRFQHook hook = new IntentRFQHook{salt: salt}(manager, aavePoolAddress, l1PoolAddress);

        require(address(hook) == expectedAddress, "Hook address mismatch!");

        console.log("IntentRFQHook successfully deployed to:", address(hook));

        vm.stopBroadcast();
    }
}
