// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

// import {UniswapV3Pool} from "@uni-core/UniswapV3Pool.sol";

/// @title Provides functions for deriving a pool address from the factory, tokens, and the fee
library PoolAddress {
    // FIXME: Ensure this value is latest & corresponds to current UniswapV3Pool code
    // keccak256(type(UniswapV3Pool).creationCode);
    bytes32 internal constant POOL_INIT_CODE_HASH =
        0xd5434d767ebc6acf4874d8815d312148f989d462d9022a440475be26b89d9269;

    /// @notice The identifying key of the pool
    struct PoolKey {
        address token0;
        address token1;
        uint24 fee;
    }

    /// @notice Returns PoolKey: the ordered tokens with the matched fee levels
    /// @param tokenA The first token of a pool, unsorted
    /// @param tokenB The second token of a pool, unsorted
    /// @param fee The fee level of the pool
    /// @return Poolkey The pool details with ordered token0 and token1 assignments
    function getPoolKey(
        address tokenA,
        address tokenB,
        uint24 fee
    ) internal pure returns (PoolKey memory) {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        return PoolKey({token0: tokenA, token1: tokenB, fee: fee});
    }

    /// @notice Deterministically computes the pool address given the factory and PoolKey
    /// @param factory The Uniswap V3 factory contract address
    /// @param key The PoolKey
    /// @return pool The contract address of the V3 pool
    function computeAddress(
        address factory,
        PoolKey memory key
    ) internal pure returns (address pool) {
        require(key.token0 < key.token1);
        pool = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            factory,
                            keccak256(
                                abi.encode(key.token0, key.token1, key.fee)
                            ),
                            POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
    }
}
