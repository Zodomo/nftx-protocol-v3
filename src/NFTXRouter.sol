// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {INonfungiblePositionManager} from "@uni-periphery/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter, SwapRouter} from "@uni-periphery/SwapRouter.sol";
import {IQuoterV2} from "@uni-periphery/interfaces/IQuoterV2.sol";
import {LowGasSafeMath} from "@uni-core/libraries/LowGasSafeMath.sol";

import {vToken} from "@mocks/vToken.sol";
// TODO: replace with IWETH
import {MockWETH} from "@mocks/MockWETH.sol";

/**
 * @notice Intermediate Router to facilitate minting + concentrated liquidity addition (and reverse)
 */
contract NFTXRouter is IERC721Receiver {
    using LowGasSafeMath for uint256;

    INonfungiblePositionManager public positionManager;
    SwapRouter public router;
    IQuoterV2 public quoter;
    IERC721 public nft;
    vToken public vtoken;
    address public WETH;

    bool public isVToken0; // check if vToken would be token0
    address token0;
    address token1;

    // TODO: dynamic fees
    uint24 public constant FEE = 3000;

    constructor(
        INonfungiblePositionManager positionManager_,
        SwapRouter router_,
        IQuoterV2 quoter_,
        IERC721 nft_,
        vToken vtoken_
    ) {
        positionManager = positionManager_;
        router = router_;
        quoter = quoter_;
        nft = nft_;
        vtoken = vtoken_;

        WETH = positionManager_.WETH9();

        if (address(vtoken_) < WETH) {
            isVToken0 = true;
            token0 = address(vtoken_);
            token1 = WETH;
        } else {
            token0 = WETH;
            token1 = address(vtoken_);
        }
    }

    struct AddLiquidityParams {
        uint256[] nftIds;
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtPriceX96;
        uint256 deadline;
    }

    /**
     * @notice User should have given NFT approval to vtoken contract, else revert
     */
    function addLiquidity(AddLiquidityParams calldata params)
        external
        payable
        returns (uint256 positionId)
    {
        uint256 vTokensAmount = vtoken.mint(
            params.nftIds,
            msg.sender,
            address(this)
        );
        vtoken.approve(address(positionManager), vTokensAmount);

        // cache
        address token0_ = token0;
        address token1_ = token1;

        positionManager.createAndInitializePoolIfNecessary(
            token0_,
            token1_,
            FEE,
            params.sqrtPriceX96
        );

        // mint position with vtoken and ETH
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        if (isVToken0) {
            amount0Desired = vTokensAmount;
            amount0Min = amount0Desired;
            amount1Desired = msg.value;
        } else {
            amount0Desired = msg.value;
            amount1Desired = vTokensAmount;
            amount1Min = amount1Min;
        }

        (positionId, , , ) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0_,
                token1: token1_,
                fee: FEE,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                recipient: msg.sender,
                deadline: params.deadline
            })
        );

        positionManager.refundETH(msg.sender);
    }

    struct RemoveLiquidityParams {
        uint256 positionId;
        uint256[] nftIds;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function removeLiquidity(RemoveLiquidityParams calldata params) external {
        // remove liquidity to get vTokens and ETH
        positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: params.positionId,
                liquidity: params.liquidity,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min,
                deadline: params.deadline
            })
        );

        // collect vtokens & weth from removing liquidity + earned fees
        (uint256 amount0, uint256 amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: params.positionId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        uint256 vTokenAmt;
        uint256 wethAmt;
        if (isVToken0) {
            vTokenAmt = amount0;
            wethAmt = amount1;
        } else {
            wethAmt = amount0;
            vTokenAmt = amount1;
        }

        // swap decimal part of vTokens to WETH
        uint256 fractionalVTokenAmt = vTokenAmt % 1 ether;
        if (fractionalVTokenAmt > 0) {
            vtoken.approve(address(router), fractionalVTokenAmt);
            uint256 fractionalWethAmt = router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(vtoken),
                    tokenOut: WETH,
                    fee: FEE,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: fractionalVTokenAmt,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
            wethAmt = wethAmt.add(fractionalWethAmt);
        }
        // send all ETH to sender
        MockWETH(WETH).withdraw(wethAmt);
        (bool success, ) = msg.sender.call{value: wethAmt}("");
        require(success, "UnableToSendETH");
        // burn vTokens to provided tokenIds array
        vtoken.burn(params.nftIds, address(this), msg.sender);
    }

    /**
     * @param sqrtPriceLimitX96 the price limit, if reached, stop swapping
     */
    struct SellNFTsParams {
        uint256[] nftIds;
        uint256 deadline;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /**
     * @notice User should have given NFT approval to vtoken contract, else revert
     */
    function sellNFTs(SellNFTsParams calldata params)
        external
        returns (uint256 wethReceived)
    {
        uint256 vTokensAmount = vtoken.mint(
            params.nftIds,
            msg.sender,
            address(this)
        );
        vtoken.approve(address(router), vTokensAmount);

        wethReceived = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(vtoken),
                tokenOut: WETH,
                fee: FEE,
                recipient: address(this),
                deadline: params.deadline,
                amountIn: vTokensAmount,
                amountOutMinimum: params.amountOutMinimum,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            })
        );

        // convert WETH to ETH & send to user
        MockWETH(WETH).withdraw(wethReceived);
        (bool success, ) = msg.sender.call{value: wethReceived}("");
        require(success, "UnableToSendETH");
    }

    /**
     * @param sqrtPriceLimitX96 the price limit, if reached, stop swapping
     */
    struct BuyNFTsParams {
        uint256[] nftIds;
        uint256 deadline;
        uint160 sqrtPriceLimitX96;
    }

    function buyNFTs(BuyNFTsParams calldata params) external payable {
        uint256 vTokenAmt = params.nftIds.length.mul(1 ether);

        // swap ETH to required vTokens amount
        router.exactOutputSingle{value: msg.value}(
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: WETH,
                tokenOut: address(vtoken),
                fee: FEE,
                recipient: address(this),
                deadline: params.deadline,
                amountOut: vTokenAmt,
                amountInMaximum: msg.value,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            })
        );

        // unwrap vTokens to tokenIds specified, and send to sender
        vtoken.burn(params.nftIds, address(this), msg.sender);

        // refund ETH
        router.refundETH(msg.sender);
    }

    /**
     * @dev These functions are not gas efficient and should _not_ be called on chain. Instead, optimistically execute
     * the swap and check the amounts in the callback.
     */
    function quoteBuyNFTs(uint256[] memory nftIds, uint160 sqrtPriceLimitX96)
        external
        returns (uint256 ethRequired)
    {
        uint256 vTokenAmt = nftIds.length.mul(1 ether);

        (ethRequired, , , ) = quoter.quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: WETH,
                tokenOut: address(vtoken),
                amount: vTokenAmt,
                fee: FEE,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            })
        );
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}