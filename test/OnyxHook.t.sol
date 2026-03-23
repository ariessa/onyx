// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TestERC20} from "@uniswap/v4-core/src/test/TestERC20.sol";

import {OnyxHook} from "../src/OnyxHook.sol";

contract OnyxHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    TestERC20 token0;
    TestERC20 token1;
    Currency currency0;
    Currency currency1;

    OnyxHook hook;
    PoolKey poolKey;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant BATCH_WINDOW = 60; // 60 seconds
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // sqrt(1) * 2^96

    function setUp() public {
        // 1. Deploy PoolManager
        manager = new PoolManager(address(this));

        // 2. Deploy test routers
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // 3. Deploy tokens and sort them
        token0 = new TestERC20(2 ** 128);
        token1 = new TestERC20(2 ** 128);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // 4. Deploy OnyxHook at address with beforeSwap flag
        uint160 hookFlags = uint160(Hooks.BEFORE_SWAP_FLAG);
        address hookAddress = address(hookFlags);
        deployCodeTo("OnyxHook.sol:OnyxHook", abi.encode(manager, BATCH_WINDOW), hookAddress);
        hook = OnyxHook(hookAddress);

        // 5. Pool key + init
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // 6. Approvals
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);

        // 7. Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10e18,
                salt: 0
            }),
            ""
        );

        // 8. Fund test users
        token0.mint(alice, 10_000e18);
        token1.mint(alice, 10_000e18);
        token0.mint(bob, 10_000e18);
        token1.mint(bob, 10_000e18);
        token0.mint(carol, 10_000e18);
        token1.mint(carol, 10_000e18);
    }

    // ─── helpers ────────────────────────────────────────────────

    /// Shield helper: returns the derived commitment for use in subsequent calls.
    function _shield(address user, uint256 secret, uint256 nullifier, Currency currency, uint256 amount)
        internal
        returns (uint256 commitment)
    {
        commitment = hook.computeCommitment(secret, nullifier);
        vm.startPrank(user);
        TestERC20(Currency.unwrap(currency)).approve(address(hook), amount);
        hook.shield(secret, nullifier, currency, amount);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //                    COMMITMENT TESTS
    // ═══════════════════════════════════════════════════════════

    function test_computeCommitment_isDeterministic() public view {
        uint256 c1 = hook.computeCommitment(111, 222);
        uint256 c2 = hook.computeCommitment(111, 222);
        assertEq(c1, c2);
    }

    function test_computeCommitment_uniquePerInputs() public view {
        uint256 c1 = hook.computeCommitment(1, 2);
        uint256 c2 = hook.computeCommitment(1, 3);
        uint256 c3 = hook.computeCommitment(2, 2);
        assertTrue(c1 != c2);
        assertTrue(c1 != c3);
        assertTrue(c2 != c3);
    }

    function test_computeNullifierHash_isDeterministic() public view {
        uint256 h1 = hook.computeNullifierHash(999);
        uint256 h2 = hook.computeNullifierHash(999);
        assertEq(h1, h2);
    }

    function test_computeNullifierHash_uniquePerNullifier() public view {
        assertTrue(hook.computeNullifierHash(1) != hook.computeNullifierHash(2));
    }

    // ═══════════════════════════════════════════════════════════
    //                      SHIELD TESTS
    // ═══════════════════════════════════════════════════════════

    function test_shield_depositsTokens() public {
        uint256 amount = 1000e18;
        uint256 commitment = _shield(alice, 111, 222, currency0, amount);

        assertTrue(hook.commitments(commitment));
        assertEq(hook.commitmentCount(), 1);
        assertEq(hook.totalShielded(currency0), amount);
        assertEq(token0.balanceOf(address(hook)), amount);
    }

    function test_shield_revertsOnDuplicateCommitment() public {
        // Same secret+nullifier → same commitment → should revert
        vm.startPrank(alice);
        token0.approve(address(hook), 2000e18);
        hook.shield(111, 222, currency0, 1000e18);
        vm.expectRevert(OnyxHook.CommitmentAlreadyExists.selector);
        hook.shield(111, 222, currency0, 500e18);
        vm.stopPrank();
    }

    function test_shield_revertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(OnyxHook.ZeroAmount.selector);
        hook.shield(111, 222, currency0, 0);
    }

    function test_shield_multipleDeposits() public {
        _shield(alice, 1, 2, currency0, 1000e18);
        _shield(alice, 3, 4, currency0, 2000e18);

        assertEq(hook.commitmentCount(), 2);
        assertEq(hook.totalShielded(currency0), 3000e18);
    }

    // ═══════════════════════════════════════════════════════════
    //                      WITHDRAW TESTS
    // ═══════════════════════════════════════════════════════════

    function test_withdraw_sendsTokensToRecipient() public {
        uint256 amount = 1000e18;
        _shield(alice, 111, 222, currency0, amount);
        uint256 commitment = hook.computeCommitment(111, 222);

        address recipient = makeAddr("recipient");
        uint256 balBefore = token0.balanceOf(recipient);

        hook.withdraw(hex"01", commitment, 222, recipient, currency0, amount);

        assertEq(token0.balanceOf(recipient), balBefore + amount);
        assertEq(hook.totalShielded(currency0), 0);
    }

    function test_withdraw_marksNullifierSpent() public {
        _shield(alice, 111, 222, currency0, 1000e18);
        uint256 commitment = hook.computeCommitment(111, 222);
        uint256 nullifierHash = hook.computeNullifierHash(222);

        assertFalse(hook.nullifierHashes(nullifierHash));
        hook.withdraw(hex"01", commitment, 222, alice, currency0, 1000e18);
        assertTrue(hook.nullifierHashes(nullifierHash));
    }

    function test_withdraw_revertsOnDoubleSpend() public {
        _shield(alice, 111, 222, currency0, 1000e18);
        uint256 commitment = hook.computeCommitment(111, 222);

        hook.withdraw(hex"01", commitment, 222, alice, currency0, 500e18);

        vm.expectRevert(OnyxHook.NullifierAlreadySpent.selector);
        hook.withdraw(hex"01", commitment, 222, alice, currency0, 500e18);
    }

    function test_withdraw_revertsOnUnknownCommitment() public {
        vm.expectRevert(OnyxHook.UnknownCommitment.selector);
        hook.withdraw(hex"01", 999999, 222, alice, currency0, 100);
    }

    function test_withdraw_revertsOnEmptyProof() public {
        _shield(alice, 111, 222, currency0, 1000e18);
        uint256 commitment = hook.computeCommitment(111, 222);

        vm.expectRevert(OnyxHook.InvalidProof.selector);
        hook.withdraw("", commitment, 222, alice, currency0, 1000e18);
    }

    function test_withdraw_revertsOnZeroAmount() public {
        _shield(alice, 111, 222, currency0, 1000e18);
        uint256 commitment = hook.computeCommitment(111, 222);

        vm.expectRevert(OnyxHook.ZeroAmount.selector);
        hook.withdraw(hex"01", commitment, 222, alice, currency0, 0);
    }

    // ═══════════════════════════════════════════════════════════
    //                   SUBMIT INTENT TESTS
    // ═══════════════════════════════════════════════════════════

    function test_submitIntent_basic() public {
        uint256 commitment = _shield(alice, 111, 222, currency0, 1000e18);
        uint256 nullifierHash = hook.computeNullifierHash(222);
        uint256 newCommitment = hook.computeCommitment(333, 444);

        hook.submitIntent(hex"01", commitment, nullifierHash, 500e18, true, makeAddr("stealth_alice"), newCommitment);

        assertTrue(hook.nullifierHashes(nullifierHash));
        assertEq(hook.batchBuyTotal(1), 500e18);
        assertEq(hook.getBatchIntentCount(1), 1);
        assertTrue(hook.commitments(newCommitment));
    }

    function test_submitIntent_revertsOnUnknownCommitment() public {
        vm.expectRevert(OnyxHook.UnknownCommitment.selector);
        hook.submitIntent(hex"01", 999999, 200, 500e18, true, makeAddr("stealth"), 300);
    }

    function test_submitIntent_revertsOnSpentNullifier() public {
        uint256 c1 = _shield(alice, 111, 222, currency0, 1000e18);
        uint256 nh = hook.computeNullifierHash(222);
        hook.submitIntent(hex"01", c1, nh, 500e18, true, makeAddr("s1"), 0);

        uint256 c2 = _shield(bob, 333, 444, currency0, 1000e18);
        vm.expectRevert(OnyxHook.NullifierAlreadySpent.selector);
        hook.submitIntent(hex"01", c2, nh, 500e18, true, makeAddr("s2"), 0);
    }

    function test_submitIntent_revertsOnEmptyProof() public {
        uint256 commitment = _shield(alice, 111, 222, currency0, 1000e18);
        uint256 nullifierHash = hook.computeNullifierHash(222);

        vm.expectRevert(OnyxHook.InvalidProof.selector);
        hook.submitIntent("", commitment, nullifierHash, 500e18, true, makeAddr("stealth"), 0);
    }

    function test_submitIntent_accumulatesBothDirections() public {
        uint256 ca = _shield(alice, 111, 222, currency0, 1000e18);
        uint256 cb = _shield(bob, 333, 444, currency1, 800e18);

        hook.submitIntent(hex"01", ca, hook.computeNullifierHash(222), 1000e18, true, makeAddr("sa"), 0);
        hook.submitIntent(hex"01", cb, hook.computeNullifierHash(444), 800e18, false, makeAddr("sb"), 0);

        assertEq(hook.batchBuyTotal(1), 1000e18);
        assertEq(hook.batchSellTotal(1), 800e18);
        assertEq(hook.getBatchIntentCount(1), 2);
    }

    // ═══════════════════════════════════════════════════════════
    //                   SETTLE BATCH TESTS
    // ═══════════════════════════════════════════════════════════

    function test_settleBatch_revertsBeforeWindow() public {
        uint256 commitment = _shield(alice, 111, 222, currency0, 1000e18);
        hook.submitIntent(hex"01", commitment, hook.computeNullifierHash(222), 500e18, true, makeAddr("s"), 0);

        vm.expectRevert(OnyxHook.BatchNotReady.selector);
        hook.settleBatch(1, poolKey);
    }

    function test_settleBatch_revertsOnAlreadySettled() public {
        uint256 commitment = _shield(alice, 111, 222, currency0, 1000e18);
        hook.submitIntent(hex"01", commitment, hook.computeNullifierHash(222), uint128(100), true, makeAddr("s"), 0);

        vm.warp(block.timestamp + BATCH_WINDOW + 1);
        hook.settleBatch(1, poolKey);

        vm.expectRevert(OnyxHook.BatchAlreadySettled.selector);
        hook.settleBatch(1, poolKey);
    }

    function test_settleBatch_advancesBatchId() public {
        uint256 commitment = _shield(alice, 111, 222, currency0, 1000e18);
        hook.submitIntent(hex"01", commitment, hook.computeNullifierHash(222), uint128(100), true, makeAddr("s"), 0);

        assertEq(hook.currentBatchId(), 1);
        vm.warp(block.timestamp + BATCH_WINDOW + 1);
        hook.settleBatch(1, poolKey);

        assertEq(hook.currentBatchId(), 2);
        assertTrue(hook.batchSettled(1));
    }

    function test_settleBatch_nettingWithResidualSwap() public {
        uint256 ca = _shield(alice, 111, 222, currency0, 1000e18);
        uint256 cb = _shield(bob, 333, 444, currency1, 500e18);

        address aliceStealth = makeAddr("as");
        address bobStealth = makeAddr("bs");

        hook.submitIntent(hex"01", ca, hook.computeNullifierHash(222), uint128(1000), true, aliceStealth, 0);
        hook.submitIntent(hex"01", cb, hook.computeNullifierHash(444), uint128(500), false, bobStealth, 0);

        vm.warp(block.timestamp + BATCH_WINDOW + 1);
        hook.settleBatch(1, poolKey);

        assertTrue(hook.batchSettled(1));
        assertEq(hook.currentBatchId(), 2);

        // Minority side (Bob, seller) should receive currency0 from internal crossing
        assertGt(token0.balanceOf(bobStealth), 0, "minority side should receive crossed tokens");
        // Majority side (Alice, buyer) should receive currency1 from both crossing and AMM
        assertGt(token1.balanceOf(aliceStealth), 0, "majority side should receive output tokens");
    }

    // ═══════════════════════════════════════════════════════════
    //                  PUBLIC SWAP PASSTHROUGH
    // ═══════════════════════════════════════════════════════════

    function test_publicSwap_passesThroughHook() public {
        BalanceDelta delta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -100,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertTrue(delta.amount0() != 0 || delta.amount1() != 0);
    }

    // ═══════════════════════════════════════════════════════════
    //                    VIEW HELPERS
    // ═══════════════════════════════════════════════════════════

    function test_getBatchIntent_returnsCorrectData() public {
        uint256 commitment = _shield(alice, 111, 222, currency0, 1000e18);
        uint256 nullifierHash = hook.computeNullifierHash(222);
        address stealthAddr = makeAddr("stealth_alice");

        hook.submitIntent(hex"01", commitment, nullifierHash, 500e18, true, stealthAddr, 0);

        OnyxHook.Intent memory intent = hook.getBatchIntent(1, 0);
        assertEq(intent.nullifierHash, nullifierHash);
        assertEq(intent.amount, 500e18);
        assertTrue(intent.zeroForOne);
        assertEq(intent.stealthAddress, stealthAddr);
    }

    function test_hookPermissions() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.beforeSwap);
        assertFalse(perms.afterSwap);
        assertFalse(perms.beforeInitialize);
        assertFalse(perms.afterInitialize);
        assertFalse(perms.beforeAddLiquidity);
        assertFalse(perms.afterAddLiquidity);
        assertFalse(perms.beforeRemoveLiquidity);
        assertFalse(perms.afterRemoveLiquidity);
        assertFalse(perms.beforeDonate);
        assertFalse(perms.afterDonate);
    }
}
