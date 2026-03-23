// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @title OnyxHook — Privacy-preserving dark pool as a Uniswap v4 Hook
/// @notice Batch-netting dark pool: users shield tokens, submit swap intents,
///         and a permissionless settler nets opposing sides and swaps only the
///         residual through the Uniswap v4 pool. Commitments use keccak256 hashing.
contract OnyxHook is IHooks, IUnlockCallback {
    using Hooks for IHooks;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    // ═══════════════════════════════════════════════════════════
    //                        IMMUTABLES
    // ═══════════════════════════════════════════════════════════

    IPoolManager public immutable poolManager;

    // ═══════════════════════════════════════════════════════════
    //                     COMMITMENT SET
    // ═══════════════════════════════════════════════════════════

    /// @dev Each commitment = keccak256(secret, nullifier).
    mapping(uint256 => bool) public commitments;
    uint256 public commitmentCount;

    // ═══════════════════════════════════════════════════════════
    //                     NULLIFIER TRACKING
    // ═══════════════════════════════════════════════════════════

    mapping(uint256 => bool) public nullifierHashes;

    // ═══════════════════════════════════════════════════════════
    //                    SHIELDED BALANCES
    // ═══════════════════════════════════════════════════════════

    /// @dev Tracks how much of each currency is shielded in total (for accounting).
    mapping(Currency => uint256) public totalShielded;

    // ═══════════════════════════════════════════════════════════
    //                      BATCH STATE
    // ═══════════════════════════════════════════════════════════

    struct Intent {
        uint256 nullifierHash;
        uint128 amount;
        bool zeroForOne; // true = sell currency0 for currency1
        address stealthAddress; // destination for output tokens
        uint256 newCommitment; // commitment for change note
    }

    uint64 public currentBatchId;
    uint256 public batchWindowDuration; // seconds

    mapping(uint64 => uint256) public batchStartTime;
    mapping(uint64 => uint128) public batchBuyTotal;
    mapping(uint64 => uint128) public batchSellTotal;
    mapping(uint64 => Intent[]) internal batchIntents;
    mapping(uint64 => bool) public batchSettled;

    // ═══════════════════════════════════════════════════════════
    //                         EVENTS
    // ═══════════════════════════════════════════════════════════

    event Shield(uint256 indexed commitment, uint256 amount, Currency currency);
    event Withdraw(uint256 indexed nullifierHash, uint256 amount, Currency currency, address recipient);
    event IntentSubmitted(uint64 indexed batchId, uint256 nullifierHash, bool zeroForOne);
    event BatchSettled(uint64 indexed batchId, uint256 netResidual, bool netDirection);

    // ═══════════════════════════════════════════════════════════
    //                         ERRORS
    // ═══════════════════════════════════════════════════════════

    error CommitmentAlreadyExists();
    error NullifierAlreadySpent();
    error InvalidProof();
    error UnknownCommitment();
    error BatchNotReady();
    error BatchAlreadySettled();
    error NotPoolManager();
    error ZeroAmount();
    error WithdrawAmountExceedsShielded();

    // ═══════════════════════════════════════════════════════════
    //                       CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    constructor(IPoolManager _poolManager, uint256 _batchWindowDuration) {
        poolManager = _poolManager;
        batchWindowDuration = _batchWindowDuration;

        // Validate hook address has correct flag bits
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());

        // Start first batch
        currentBatchId = 1;
        batchStartTime[1] = block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════
    //                    HOOK PERMISSIONS
    // ═══════════════════════════════════════════════════════════

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
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
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ═══════════════════════════════════════════════════════════
    //                        SHIELD
    // ═══════════════════════════════════════════════════════════

    /// @notice Deposit tokens into the dark pool. Creates a shielded commitment.
    /// @param secret     Private random value known only to the depositor.
    /// @param nullifier  Private value whose hash will be revealed on spend.
    /// @param currency   The token to shield.
    /// @param amount     Amount to shield.
    function shield(uint256 secret, uint256 nullifier, Currency currency, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        // Derive commitment on-chain — proves the user knows (secret, nullifier).
        uint256 commitment = computeCommitment(secret, nullifier);
        if (commitments[commitment]) revert CommitmentAlreadyExists();

        IERC20Minimal(Currency.unwrap(currency)).transferFrom(msg.sender, address(this), amount);

        commitments[commitment] = true;
        commitmentCount++;
        totalShielded[currency] += amount;

        emit Shield(commitment, amount, currency);
    }

    // ═══════════════════════════════════════════════════════════
    //                        WITHDRAW
    // ═══════════════════════════════════════════════════════════

    /// @notice Withdraw shielded tokens without swapping.
    ///         Spends the commitment via its nullifier — cannot be replayed.
    /// @param proof         ZK proof bytes (non-empty required; verifier is pluggable).
    /// @param commitment    The commitment being spent.
    /// @param nullifier     The nullifier preimage (reveals nullifierHash on-chain).
    /// @param recipient     Address to receive the tokens.
    /// @param currency      Which token to withdraw.
    /// @param amount        Amount to withdraw.
    function withdraw(
        bytes calldata proof,
        uint256 commitment,
        uint256 nullifier,
        address recipient,
        Currency currency,
        uint256 amount
    ) external {
        if (amount == 0) revert ZeroAmount();
        if (!commitments[commitment]) revert UnknownCommitment();
        if (proof.length == 0) revert InvalidProof();

        uint256 nullifierHash = computeNullifierHash(nullifier);
        if (nullifierHashes[nullifierHash]) revert NullifierAlreadySpent();
        if (totalShielded[currency] < amount) revert WithdrawAmountExceedsShielded();

        // Mark spent
        nullifierHashes[nullifierHash] = true;
        totalShielded[currency] -= amount;

        IERC20Minimal(Currency.unwrap(currency)).transfer(recipient, amount);

        emit Withdraw(nullifierHash, amount, currency, recipient);
    }

    // ═══════════════════════════════════════════════════════════
    //                     SUBMIT INTENT
    // ═══════════════════════════════════════════════════════════

    /// @notice Submit a private swap intent to the current batch.
    /// @param proof ZK proof bytes (non-empty required; verifier is pluggable)
    /// @param commitment The commitment being spent
    /// @param nullifierHash Hash of the nullifier (prevents double-spend)
    /// @param amount Swap amount
    /// @param zeroForOne true = sell currency0 for currency1
    /// @param stealthAddress Destination address for output tokens
    /// @param newCommitment Commitment for any change/remaining balance
    function submitIntent(
        bytes calldata proof,
        uint256 commitment,
        uint256 nullifierHash,
        uint128 amount,
        bool zeroForOne,
        address stealthAddress,
        uint256 newCommitment
    ) external {
        if (!commitments[commitment]) revert UnknownCommitment();
        if (nullifierHashes[nullifierHash]) revert NullifierAlreadySpent();
        if (proof.length == 0) revert InvalidProof();

        nullifierHashes[nullifierHash] = true;
        uint64 batchId = currentBatchId;
        if (zeroForOne) {
            batchBuyTotal[batchId] += amount;
        } else {
            batchSellTotal[batchId] += amount;
        }

        batchIntents[batchId].push(
            Intent({
                nullifierHash: nullifierHash,
                amount: amount,
                zeroForOne: zeroForOne,
                stealthAddress: stealthAddress,
                newCommitment: newCommitment
            })
        );

        if (newCommitment != 0) {
            commitments[newCommitment] = true;
            commitmentCount++;
        }

        emit IntentSubmitted(batchId, nullifierHash, zeroForOne);
    }

    // ═══════════════════════════════════════════════════════════
    //                     SETTLE BATCH
    // ═══════════════════════════════════════════════════════════

    /// @notice Settle the batch: net buy/sell, swap residual through the pool,
    ///         distribute output to stealth addresses.
    /// @param batchId The batch to settle
    /// @param poolKey The pool to swap residual through
    function settleBatch(uint64 batchId, PoolKey calldata poolKey) external {
        if (batchSettled[batchId]) revert BatchAlreadySettled();
        if (block.timestamp < batchStartTime[batchId] + batchWindowDuration) revert BatchNotReady();

        batchSettled[batchId] = true;

        uint128 buys = batchBuyTotal[batchId]; // total wanting to go 0→1
        uint128 sells = batchSellTotal[batchId]; // total wanting to go 1→0

        // Net the batch: internal crossing cancels out
        uint128 matched = buys < sells ? buys : sells;
        uint128 netResidual;
        bool netZeroForOne;

        if (buys >= sells) {
            netResidual = buys - sells;
            netZeroForOne = true; // net demand is 0→1
        } else {
            netResidual = sells - buys;
            netZeroForOne = false; // net demand is 1→0
        }

        // 1. Distribute internally-crossed tokens to both sides
        if (matched > 0) {
            _distributeMatched(batchId, poolKey, matched, buys, sells);
        }

        // 2. Swap residual through AMM and distribute to majority side
        if (netResidual > 0) {
            // Approve pool manager to pull tokens
            Currency inputCurrency = netZeroForOne ? poolKey.currency0 : poolKey.currency1;
            IERC20Minimal(Currency.unwrap(inputCurrency)).approve(address(poolManager), netResidual);

            bytes memory callbackData = abi.encode(poolKey, netResidual, netZeroForOne, batchId);
            poolManager.unlock(callbackData);

            // Update shielded accounting for AMM input
            totalShielded[inputCurrency] -= netResidual;
        }

        // Advance to next batch
        currentBatchId = batchId + 1;
        batchStartTime[batchId + 1] = block.timestamp;

        emit BatchSettled(batchId, netResidual, netZeroForOne);
    }

    // ═══════════════════════════════════════════════════════════
    //                   UNLOCK CALLBACK
    // ═══════════════════════════════════════════════════════════

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        (PoolKey memory poolKey, uint128 netResidual, bool netZeroForOne, uint64 batchId) =
            abi.decode(data, (PoolKey, uint128, bool, uint64));

        // Execute the net swap
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: netZeroForOne,
            amountSpecified: -int256(uint256(netResidual)), // exact input
            sqrtPriceLimitX96: netZeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = poolManager.swap(poolKey, swapParams, "");

        // Settle: send input tokens to pool manager
        Currency inputCurrency = netZeroForOne ? poolKey.currency0 : poolKey.currency1;
        Currency outputCurrency = netZeroForOne ? poolKey.currency1 : poolKey.currency0;

        // Amount we owe (negative delta = we owe)
        int128 inputDelta = netZeroForOne ? delta.amount0() : delta.amount1();
        if (inputDelta < 0) {
            uint256 amountOwed = uint256(uint128(-inputDelta));
            poolManager.sync(inputCurrency);
            IERC20Minimal(Currency.unwrap(inputCurrency)).transfer(address(poolManager), amountOwed);
            poolManager.settle();
        }

        // Take: receive output tokens
        int128 outputDelta = netZeroForOne ? delta.amount1() : delta.amount0();
        if (outputDelta > 0) {
            uint256 amountReceived = uint256(uint128(outputDelta));
            poolManager.take(outputCurrency, address(this), amountReceived);

            // Distribute output to stealth addresses proportionally
            _distributeOutput(batchId, outputCurrency, amountReceived, netZeroForOne);
        }

        return "";
    }

    // ═══════════════════════════════════════════════════════════
    //                  INTERNAL CROSSING
    // ═══════════════════════════════════════════════════════════

    /// @dev Distribute internally-crossed tokens to both sides of the batch.
    ///      Buyers (zeroForOne=true) deposited currency0 and want currency1.
    ///      Sellers (zeroForOne=false) deposited currency1 and want currency0.
    ///      The crossed portion is fulfilled from each side's shielded deposits.
    function _distributeMatched(
        uint64 batchId,
        PoolKey calldata poolKey,
        uint128 matched,
        uint128 totalBuys,
        uint128 totalSells
    ) internal {
        Intent[] storage intents = batchIntents[batchId];

        // Buyers want currency1 — give them their share of crossed currency1
        for (uint256 i = 0; i < intents.length; i++) {
            if (intents[i].zeroForOne) {
                uint256 share = (uint256(matched) * intents[i].amount) / totalBuys;
                if (share > 0) {
                    IERC20Minimal(Currency.unwrap(poolKey.currency1)).transfer(intents[i].stealthAddress, share);
                }
            }
        }

        // Sellers want currency0 — give them their share of crossed currency0
        for (uint256 i = 0; i < intents.length; i++) {
            if (!intents[i].zeroForOne) {
                uint256 share = (uint256(matched) * intents[i].amount) / totalSells;
                if (share > 0) {
                    IERC20Minimal(Currency.unwrap(poolKey.currency0)).transfer(intents[i].stealthAddress, share);
                }
            }
        }

        // Update shielded accounting — crossed tokens leave the pool
        totalShielded[poolKey.currency0] -= matched;
        totalShielded[poolKey.currency1] -= matched;
    }

    // ═══════════════════════════════════════════════════════════
    //                   AMM OUTPUT DISTRIBUTION
    // ═══════════════════════════════════════════════════════════

    /// @dev Distribute AMM swap output to majority-side stealth addresses proportionally.
    function _distributeOutput(
        uint64 batchId,
        Currency outputCurrency,
        uint256 totalOutput,
        bool netZeroForOne
    ) internal {
        Intent[] storage intents = batchIntents[batchId];
        uint128 totalMatchingSide;

        // Sum all intents going in the net direction
        for (uint256 i = 0; i < intents.length; i++) {
            if (intents[i].zeroForOne == netZeroForOne) {
                totalMatchingSide += intents[i].amount;
            }
        }

        if (totalMatchingSide == 0) return;

        // Distribute proportionally
        for (uint256 i = 0; i < intents.length; i++) {
            if (intents[i].zeroForOne == netZeroForOne) {
                uint256 share = (totalOutput * intents[i].amount) / totalMatchingSide;
                if (share > 0) {
                    IERC20Minimal(Currency.unwrap(outputCurrency)).transfer(intents[i].stealthAddress, share);
                }
            }
        }

    }

    // ═══════════════════════════════════════════════════════════
    //                   HOOK CALLBACKS
    // ═══════════════════════════════════════════════════════════

    /// @dev beforeSwap: allow public swaps, no-op
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ═══════════════════════════════════════════════════════════
    //                 UNUSED HOOK CALLBACKS
    //        (required by IHooks, all return selector)
    // ═══════════════════════════════════════════════════════════

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    // ═══════════════════════════════════════════════════════════
    //                       VIEW HELPERS
    // ═══════════════════════════════════════════════════════════

    /// @notice Compute commitment = hash(secret, nullifier).
    function computeCommitment(uint256 secret, uint256 nullifier) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(secret, nullifier)));
    }

    /// @notice Compute the nullifier hash that gets recorded when a commitment is spent.
    function computeNullifierHash(uint256 nullifier) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(nullifier)));
    }

    function getBatchIntentCount(uint64 batchId) external view returns (uint256) {
        return batchIntents[batchId].length;
    }

    function getBatchIntent(uint64 batchId, uint256 index) external view returns (Intent memory) {
        return batchIntents[batchId][index];
    }
}
