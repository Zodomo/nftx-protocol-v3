// SPDX-License-Identifier: MIT
pragma solidity =0.8.15;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {INonfungiblePositionManager} from "@uni-periphery/interfaces/INonfungiblePositionManager.sol";
import {SwapRouter} from "@uni-periphery/SwapRouter.sol";
import {IQuoterV2} from "@uni-periphery/interfaces/IQuoterV2.sol";

import {INFTXVaultFactory} from "@src/v2/interface/INFTXVaultFactory.sol";

interface INFTXRouter {
    // =============================================================
    //                           CONSTANTS
    // =============================================================

    function WETH() external returns (address);

    function CRYPTO_PUNKS() external returns (address);

    function positionManager() external returns (INonfungiblePositionManager);

    function router() external returns (SwapRouter);

    function quoter() external returns (IQuoterV2);

    function nftxVaultFactory() external returns (INFTXVaultFactory);

    // =============================================================
    //                            ERRORS
    // =============================================================

    error UnableToSendETH();

    // =============================================================
    //                     PUBLIC / EXTERNAL WRITE
    // =============================================================

    struct AddLiquidityParams {
        address vtoken;
        uint256 vTokensAmount; // user can provide just vTokens or NFTs or both
        uint256[] nftIds;
        int24 tickLower;
        int24 tickUpper;
        uint24 fee;
        uint160 sqrtPriceX96;
        uint256 deadline;
    }

    /**
     * @notice User should have given NFT approval to vtoken contract, else revert
     */
    function addLiquidity(
        AddLiquidityParams calldata params
    ) external payable returns (uint256 positionId);

    struct RemoveLiquidityParams {
        uint256 positionId;
        address vtoken;
        uint256[] nftIds;
        bool receiveVTokens; // directly receive vTokens, instead of redeeming for NFTs
        uint128 liquidity;
        uint24 swapPoolFee; // the pool through which the fractional vToken to ETH swap should go through
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function removeLiquidity(RemoveLiquidityParams calldata params) external;

    /**
     * @param sqrtPriceLimitX96 the price limit, if reached, stop swapping
     */
    struct SellNFTsParams {
        address vtoken;
        uint256[] nftIds;
        uint256 deadline;
        uint24 fee;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /**
     * @notice User should have given NFT approval to vtoken contract, else revert
     */
    function sellNFTs(
        SellNFTsParams calldata params
    ) external returns (uint256 wethReceived);

    /**
     * @param sqrtPriceLimitX96 the price limit, if reached, stop swapping
     */
    struct BuyNFTsParams {
        address vtoken;
        uint256[] nftIds;
        uint256 deadline;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function buyNFTs(BuyNFTsParams calldata params) external payable;

    // =============================================================
    //                        ONLY OWNER WRITE
    // =============================================================

    /**
     * @param token ERC20 token address or address(0) in case of ETH
     */
    function rescueTokens(IERC20 token) external;

    // =============================================================
    //                     PUBLIC / EXTERNAL VIEW
    // =============================================================

    /**
     * @dev This function is not gas efficient and should _not_ be called on chain.
     */
    function quoteBuyNFTs(
        address vtoken,
        uint256[] memory nftIds,
        uint24 fee,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 ethRequired);

    /**
     * @notice Get deployed pool address for vaultId. `exists` is false if pool doesn't exist. `vaultId` must be valid.
     */
    function getPoolExists(
        uint256 vaultId,
        uint24 fee
    ) external view returns (address pool, bool exists);

    /**
     * @notice Get deployed pool address for vToken. Reverts if pool doesn't exist
     */
    function getPool(
        address vToken_,
        uint24 fee
    ) external view returns (address pool);

    /**
     * @notice Compute the pool address corresponding to vToken
     */
    function computePool(
        address vToken_,
        uint24 fee
    ) external view returns (address);

    /**
     * @notice Checks if vToken is token0 or not
     */
    function isVToken0(address vtoken) external view returns (bool);
}