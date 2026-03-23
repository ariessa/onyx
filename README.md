> **Disclaimer**: This is a submission for Uniswap Hook Incubator — Cohort 8. It has not been audited and is not intended for production use. The author assumes no liability for any loss of funds or other damages resulting from the use of this code. Use at your own risk.

<br />

# Onyx

Onyx is a privacy-preserving dark pool built as a **Uniswap v4 Hook**. Users shield tokens, submit swap intents, and a permissionless settler nets opposing sides — only the residual hits the AMM. An observer sees one aggregated swap, not individual amounts or destinations.

<br />

## How it works

```
shield()        — deposit tokens, record a keccak256 commitment
withdraw()      — exit the dark pool without swapping
submitIntent()  — add a swap intent to the current batch
settleBatch()   — net buys vs sells, swap residual via Uniswap v4, distribute to stealth addresses
```

<br />

## Requirements

- Foundry

<br />

## Setup

```bash
git clone --recurse-submodules <repo>
cd onyx
forge build
```

<br />

## Tests

```bash
forge test -vv
```

26 tests covering the full dark pool flow:

**Commitments**
- `test_computeCommitment_isDeterministic` — same inputs produce same commitment
- `test_computeCommitment_uniquePerInputs` — different inputs produce different commitments
- `test_computeNullifierHash_isDeterministic` — nullifier hash is deterministic
- `test_computeNullifierHash_uniquePerNullifier` — different nullifiers produce different hashes

**Shield (deposit)**
- `test_shield_depositsTokens` — tokens transferred, commitment recorded
- `test_shield_revertsOnDuplicateCommitment` — can't reuse a commitment
- `test_shield_revertsOnZeroAmount` — zero deposit rejected
- `test_shield_multipleDeposits` — multiple deposits accumulate correctly

**Withdraw**
- `test_withdraw_sendsTokensToRecipient` — tokens sent to recipient
- `test_withdraw_marksNullifierSpent` — nullifier marked as spent
- `test_withdraw_revertsOnDoubleSpend` — same nullifier can't be used twice
- `test_withdraw_revertsOnUnknownCommitment` — unknown commitment rejected
- `test_withdraw_revertsOnEmptyProof` — empty proof rejected
- `test_withdraw_revertsOnZeroAmount` — zero withdraw rejected

**Submit Intent**
- `test_submitIntent_basic` — intent stored, nullifier spent, batch updated
- `test_submitIntent_revertsOnUnknownCommitment` — unknown commitment rejected
- `test_submitIntent_revertsOnSpentNullifier` — double-spend prevented
- `test_submitIntent_revertsOnEmptyProof` — empty proof rejected
- `test_submitIntent_accumulatesBothDirections` — buy and sell sides accumulate

**Settle Batch**
- `test_settleBatch_revertsBeforeWindow` — can't settle before batch window ends
- `test_settleBatch_revertsOnAlreadySettled` — can't settle twice
- `test_settleBatch_advancesBatchId` — batch ID advances after settlement
- `test_settleBatch_nettingWithResidualSwap` — buys/sells net, residual swaps via pool

**Hook Integration**
- `test_publicSwap_passesThroughHook` — normal swaps still work
- `test_getBatchIntent_returnsCorrectData` — view helper returns correct intent data
- `test_hookPermissions` — only `beforeSwap` is enabled

<br />

## Deploy (local)

```bash
anvil &
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
```

<br />

## Deployed Addresses (Base Sepolia)

| Contract | Address |
|---|---|
| OnyxHook | `0xa3813e4c116d78a85f882b496df7575382478080` |
| PoolManager | `0xdcdf244ad2a4d83b060d4d7fa4fa62a2232caeee` |
| Token0 | `0x031e390aa658264679f337054525a4fd3ade79d3` |
| Token1 | `0xc34d90ba62d33b8fdc03a250e0c69f31f7d5cafd` |

<br />

## Deploy (Base Sepolia)

```bash
# One-time: import your wallet
cast wallet import onyx-deployer --interactive

# Deploy + verify on Blockscout (no API key needed)
forge script script/DeployBaseSepolia.s.sol \
  --rpc-url https://sepolia.base.org \
  --account onyx-deployer \
  --broadcast --verify \
  --verifier blockscout \
  --verifier-url https://base-sepolia.blockscout.com/api/ \
  -vvvv

```

<br />

### Verify on BaseScan (manual)

Generate the standard JSON input for each contract, then upload on BaseScan
(**Verify and Publish** > **Solidity (Standard-Json-Input)** > compiler **0.8.26**).

```bash
# OnyxHook
forge verify-contract <HOOK_ADDRESS> src/OnyxHook.sol:OnyxHook \
  --chain base-sepolia \
  --constructor-args $(cast abi-encode "constructor(address,uint256)" <POOL_MANAGER> 300) \
  --show-standard-json-input > onyx.json

# PoolManager
forge verify-contract <POOL_MANAGER> lib/v4-core/src/PoolManager.sol:PoolManager \
  --chain base-sepolia \
  --constructor-args $(cast abi-encode "constructor(address)" <DEPLOYER_ADDRESS>) \
  --show-standard-json-input > poolmanager.json

# TestERC20 (run once per token address)
forge verify-contract <TOKEN_ADDRESS> lib/v4-core/src/test/TestERC20.sol:TestERC20 \
  --chain base-sepolia \
  --constructor-args $(cast abi-encode "constructor(uint256)" 340282366920938463463374607431768211455) \
  --show-standard-json-input > token.json
```

<br />

## Architecture

```
src/
  OnyxHook.sol          # Core hook — shield / withdraw / submitIntent / settleBatch
  utils/
    HookMiner.sol       # CREATE2 salt miner for hook address flag bits
script/
  Deploy.s.sol              # Local anvil deployment
  DeployBaseSepolia.s.sol   # Base Sepolia deployment
test/
  OnyxHook.t.sol        # 26 unit tests
```

<br />

## License

[MIT](LICENSE)
