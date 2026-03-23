// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title HookMiner
/// @notice Utility for finding a CREATE2 salt that produces a hook address
///         whose bottom 14 bits match the required Uniswap v4 hook flags.
library HookMiner {
    // Canonical CREATE2 factory (EIP-2470), deployed on all major EVM chains.
    address internal constant CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Mask covering all 14 hook-permission bits (bits 0-13 of the address).
    uint160 internal constant ALL_HOOK_MASK = 0x3FFF;

    /// @notice Find a salt such that the CREATE2 address has exactly `flags` in
    ///         its bottom 14 bits.
    /// @param flags   The required hook flags (e.g. Hooks.BEFORE_SWAP_FLAG).
    /// @param initCode The full creation bytecode (contract bytecode ++ constructor args).
    /// @param startSalt Start searching from this salt value (pass 0 normally).
    /// @return hookAddress The mined hook address.
    /// @return salt        The salt that produces that address.
    function find(uint160 flags, bytes memory initCode, uint256 startSalt)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(initCode);
        uint256 s = startSalt;

        while (true) {
            salt = bytes32(s);
            hookAddress = _computeAddress(salt, initCodeHash);
            if (uint160(hookAddress) & ALL_HOOK_MASK == flags) {
                return (hookAddress, salt);
            }
            unchecked {
                s++;
            }
        }
    }

    /// @notice Compute the CREATE2 address for a given salt and initcode hash.
    function _computeAddress(bytes32 salt, bytes32 initCodeHash)
        private
        pure
        returns (address)
    {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xFF),
                            CREATE2_FACTORY,
                            salt,
                            initCodeHash
                        )
                    )
                )
            )
        );
    }
}
