// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.9;

import {console} from "forge-std/Test.sol";
import {Helpers} from "./lib/Helpers.sol";
import {TestExtend} from "./lib/TestExtend.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {UniswapV3Factory} from "@uni-core/UniswapV3Factory.sol";
import {NonfungibleTokenPositionDescriptor} from "@uni-periphery/NonfungibleTokenPositionDescriptor.sol";
import {NonfungiblePositionManager, INonfungiblePositionManager} from "@uni-periphery/NonfungiblePositionManager.sol";
import {SwapRouter} from "@uni-periphery/SwapRouter.sol";
import {QuoterV2} from "@uni-periphery/lens/QuoterV2.sol";
import {TickMath} from "@uni-core/libraries/TickMath.sol";

import {MockWETH} from "@mocks/MockWETH.sol";
import {MockNFT} from "@mocks/MockNFT.sol";

import {NFTXRouter} from "@src/NFTXRouter.sol";
import {vToken} from "@src/vToken.sol";

contract NFTXRouterTests is TestExtend, IERC721Receiver {
    Factory factory;
    NonfungibleTokenPositionDescriptor descriptor;
    MockWETH weth;
    NonfungiblePositionManager positionManager;
    SwapRouter router;
    QuoterV2 quoter;

    MockNFT nft;
    vToken vtoken;
    NFTXRouter nftxRouter;

    uint256 tickDistance;

    function setUp() external {
        weth = new MockWETH();

        factory = new Factory();
        descriptor = new NonfungibleTokenPositionDescriptor(
            address(weth),
            bytes32(0)
        );

        positionManager = new NonfungiblePositionManager(
            address(factory),
            address(weth),
            address(descriptor)
        );
        router = new SwapRouter(address(factory), address(weth));
        quoter = new QuoterV2(address(factory), address(weth));

        nft = new MockNFT();
        vtoken = new vToken(nft);
        nftxRouter = new NFTXRouter(
            positionManager,
            router,
            quoter,
            nft,
            vtoken
        );
        tickDistance = uint256(
            uint24(factory.feeAmountTickSpacing(nftxRouter.FEE()))
        );
    }

    function testAddLiquidity() external {
        uint256 prePositionNFTBalance = positionManager.balanceOf(
            address(this)
        );

        (
            ,
            uint256 positionId,
            int24 _tickLower,
            int24 _tickUpper,
            uint256 ethUsed
        ) = _mintPosition(5);
        console.log("ETH Used: ", ethUsed);

        uint256 postPositionNFTBalance = positionManager.balanceOf(
            address(this)
        );
        (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = positionManager.positions(positionId);

        assertEq(
            postPositionNFTBalance - prePositionNFTBalance,
            1,
            "Position Balance didn't change"
        );
        assertEqInt24(tickLower, _tickLower, "Incorrect tickLower");
        assertEqInt24(tickUpper, _tickUpper, "Incorrect tickUpper");
        assertEqUint24(fee, nftxRouter.FEE(), "Incorrect fee");
        assertEq(
            token0,
            nftxRouter.isVToken0() ? address(vtoken) : nftxRouter.WETH(),
            "Incorrect token0"
        );
        assertEq(
            token1,
            !nftxRouter.isVToken0() ? address(vtoken) : nftxRouter.WETH(),
            "Incorrect token1"
        );
    }

    function testSellNFTs() external {
        _mintPosition(5);

        uint256 nftQty = 5;
        uint256 preETHBalance = address(this).balance;

        _sellNFTs(nftQty);

        uint256 postETHBalance = address(this).balance;
        assertGt(postETHBalance, preETHBalance, "ETH balance didn't increase");

        console.log(
            "ETH received: %s for selling %s NFTs",
            postETHBalance - preETHBalance,
            nftQty
        );
    }

    function testBuyNFTs() external {
        // TODO: verify for which mint qty this test fails
        (uint256[] memory allTokenIds, , , , ) = _mintPosition(100);

        uint256 nftQty = 2;

        // buy first 2 NFTs from this position/pool
        uint256[] memory nftIds = new uint256[](nftQty);
        nftIds[0] = allTokenIds[0];
        nftIds[1] = allTokenIds[1];

        // fetch price to pay for those NFTs
        uint256 ethRequired = nftxRouter.quoteBuyNFTs({
            nftIds: nftIds,
            sqrtPriceLimitX96: 0
        });
        // execute swap
        NFTXRouter.BuyNFTsParams memory params = NFTXRouter.BuyNFTsParams({
            nftIds: nftIds,
            deadline: block.timestamp,
            sqrtPriceLimitX96: 0
        });

        uint256 preNFTBalance = nft.balanceOf(address(this));
        uint256 preETHBalance = address(this).balance;

        nftxRouter.buyNFTs{value: ethRequired}(params);

        uint256 postNFTBalance = nft.balanceOf(address(this));
        uint256 postETHBalance = address(this).balance;

        assertEq(
            postNFTBalance - preNFTBalance,
            nftQty,
            "NFT balance didn't increase"
        );
        assertLt(postETHBalance, preETHBalance, "ETH balance didn't decrease");

        console.log(
            "ETH spent: %s for buying %s NFTs",
            preETHBalance - postETHBalance,
            nftQty
        );
    }

    function testRemoveLiquidity() external {
        uint256 nftQty = 10;
        (
            uint256[] memory allTokenIds,
            uint256 positionId,
            ,
            ,

        ) = _mintPosition(nftQty);

        _sellNFTs(5);

        uint256[] memory nftIds = new uint256[](nftQty);
        nftIds[0] = allTokenIds[0];
        nftIds[1] = allTokenIds[1];
        nftIds[2] = allTokenIds[2];
        nftIds[3] = allTokenIds[3];
        nftIds[4] = allTokenIds[4];
        nftIds[5] = allTokenIds[5];
        nftIds[6] = allTokenIds[6];
        nftIds[7] = allTokenIds[7];
        nftIds[8] = allTokenIds[8];
        nftIds[9] = allTokenIds[9];

        (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = positionManager.positions(positionId);

        positionManager.setApprovalForAll(address(nftxRouter), true);
        NFTXRouter.RemoveLiquidityParams memory params = NFTXRouter
            .RemoveLiquidityParams({
                positionId: positionId,
                nftIds: nftIds,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            });

        uint256 preNFTBalance = nft.balanceOf(address(this));
        uint256 preETHBalance = address(this).balance;

        nftxRouter.removeLiquidity(params);

        uint256 postNFTBalance = nft.balanceOf(address(this));
        uint256 postETHBalance = address(this).balance;

        assertEq(
            postNFTBalance - preNFTBalance,
            nftQty,
            "Incorrect NFT balance change"
        );
        assertGt(postETHBalance, preETHBalance, "ETH balance didn't change");
        assertEq(
            positionManager.ownerOf(positionId),
            address(this),
            "User is no longer the owner of PositionId"
        );

        console.log("ETH removed: ", postETHBalance - preETHBalance);
    }

    function _mintPosition(uint256 qty)
        internal
        returns (
            uint256[] memory tokenIds,
            uint256 positionId,
            int24 tickLower,
            int24 tickUpper,
            uint256 ethUsed
        )
    {
        tokenIds = nft.mint(qty);
        nft.setApprovalForAll(address(vtoken), true);

        // Current Eg: 1 NFT = 5 ETH, and liquidity provided in the range: 3-6 ETH per NFT
        uint256 currentNFTPrice = 5 ether; // 5 * 10^18 wei for 1*10^18 vTokens
        uint256 lowerNFTPrice = 3 ether;
        uint256 upperNFTPrice = 6 ether;

        uint160 currentSqrtP;
        if (nftxRouter.isVToken0()) {
            currentSqrtP = Helpers.encodeSqrtRatioX96(currentNFTPrice, 1 ether);
            // price = amount1 / amount0 = 1.0001^tick => tick ∝ price
            tickLower = Helpers.getTickForAmounts(
                lowerNFTPrice,
                1 ether,
                tickDistance
            );
            tickUpper = Helpers.getTickForAmounts(
                upperNFTPrice,
                1 ether,
                tickDistance
            );
        } else {
            currentSqrtP = Helpers.encodeSqrtRatioX96(1 ether, currentNFTPrice);
            tickLower = Helpers.getTickForAmounts(
                1 ether,
                upperNFTPrice,
                tickDistance
            );
            tickUpper = Helpers.getTickForAmounts(
                1 ether,
                lowerNFTPrice,
                tickDistance
            );
        }

        uint256 preETHBalance = address(this).balance;

        positionId = nftxRouter.addLiquidity{value: qty * 20 ether}(
            NFTXRouter.AddLiquidityParams({
                nftIds: tokenIds,
                tickLower: tickLower,
                tickUpper: tickUpper,
                sqrtPriceX96: currentSqrtP,
                deadline: block.timestamp
            })
        );

        ethUsed = preETHBalance - address(this).balance;
    }

    function _sellNFTs(uint256 qty) internal {
        uint256[] memory tokenIds = nft.mint(qty);
        nft.setApprovalForAll(address(vtoken), true);

        NFTXRouter.SellNFTsParams memory params = NFTXRouter.SellNFTsParams({
            nftIds: tokenIds,
            deadline: block.timestamp,
            amountOutMinimum: 1,
            sqrtPriceLimitX96: 0
        });

        uint256 preNFTBalance = nft.balanceOf(address(this));

        nftxRouter.sellNFTs(params);

        uint256 postNFTBalance = nft.balanceOf(address(this));
        assertEq(
            preNFTBalance - postNFTBalance,
            qty,
            "NFT balance didn't decrease"
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

    // to receive the refunded ETH
    receive() external payable {}
}