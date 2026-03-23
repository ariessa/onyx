// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TestERC20} from "@uniswap/v4-core/src/test/TestERC20.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {OnyxHook} from "../src/OnyxHook.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

/// @notice Deploy OnyxHook + test tokens + pool on Base Sepolia with verification.
///
/// Usage:
///   # One-time: import your wallet
///   cast wallet import onyx-deployer --interactive
///
///   forge script script/DeployBaseSepolia.s.sol \
///     --rpc-url https://sepolia.base.org \
///     --account onyx-deployer \
///     --broadcast -vvvv
contract DeployBaseSepolia is Script {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant HOOK_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG);

    function run() external {
        uint256 batchWindow = vm.envOr("BATCH_WINDOW", uint256(300));

        vm.startBroadcast();

        // 1. Deploy PoolManager
        PoolManager manager = new PoolManager(msg.sender);
        console.log("PoolManager:", address(manager));

        // 2. Deploy test tokens (sorted)
        TestERC20 tokenA = new TestERC20(type(uint128).max);
        TestERC20 tokenB = new TestERC20(type(uint128).max);
        (TestERC20 token0, TestERC20 token1) = address(tokenA) < address(tokenB)
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        console.log("Token0:", address(token0));
        console.log("Token1:", address(token1));

        // 3. Deploy OnyxHook via CREATE2 (address must have beforeSwap flag bit)
        bytes memory initCode = abi.encodePacked(
            type(OnyxHook).creationCode,
            abi.encode(manager, batchWindow)
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(HOOK_FLAGS, initCode, 0);
        (bool ok,) = HookMiner.CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        require(ok, "CREATE2 deploy failed");
        console.log("OnyxHook:", hookAddress);

        // 4. Initialize pool at 1:1 price
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        console.log("Pool initialized (fee=3000, tickSpacing=60)");

        // 5. Seed liquidity
        PoolModifyLiquidityTest liqRouter = new PoolModifyLiquidityTest(manager);
        token0.approve(address(liqRouter), type(uint256).max);
        token1.approve(address(liqRouter), type(uint256).max);
        liqRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887220,
                tickUpper: 887220,
                liquidityDelta: 10e18,
                salt: 0
            }),
            ""
        );
        console.log("Liquidity added (full range, 10e18)");

        vm.stopBroadcast();
    }
}
