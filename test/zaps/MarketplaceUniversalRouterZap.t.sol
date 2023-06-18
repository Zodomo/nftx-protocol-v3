// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.15;

import {console, stdError} from "forge-std/Test.sol";
import {Helpers} from "../lib/Helpers.sol";

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketplaceUniversalRouterZap} from "@src/zaps/MarketplaceUniversalRouterZap.sol";
import {MockUniversalRouter} from "@mocks/MockUniversalRouter.sol";
import {IQuoterV2} from "@uni-periphery/lens/QuoterV2.sol";
import {UniswapV3PoolUpgradeable, IUniswapV3Pool} from "@uni-core/UniswapV3PoolUpgradeable.sol";
import {NFTXVaultUpgradeable, INFTXVault} from "@src/v2/NFTXVaultUpgradeable.sol";
import {MockERC20} from "@mocks/MockERC20.sol";
import {NFTXRouter, INFTXRouter} from "@src/zaps/NFTXRouter.sol";

import {TestBase} from "../TestBase.sol";

contract MarketplaceUniversalRouterZapTests is TestBase {
    uint256 currentNFTPrice = 10 ether;

    // MarketplaceZap#sell721
    function test_sell721_RevertsForNonOwnerIfPaused() external {
        marketplaceZap.pause(true);

        uint256[] memory idsIn;
        bytes memory executeCallData;

        hoax(makeAddr("nonOwner"));
        vm.expectRevert(MarketplaceUniversalRouterZap.ZapPaused.selector);
        marketplaceZap.sell721(
            VAULT_ID,
            idsIn,
            executeCallData,
            payable(this),
            true
        );
    }

    function test_sell721_Success() external {
        _mintPositionWithTwap(currentNFTPrice);

        uint256 qty = 5;

        uint256[] memory idsIn = nft.mint(qty);
        bytes memory executeCallData = abi.encodeWithSelector(
            MockUniversalRouter.execute.selector,
            address(vtoken),
            qty * 1 ether,
            address(weth)
        );

        nft.setApprovalForAll(address(marketplaceZap), true);
        marketplaceZap.sell721(
            VAULT_ID,
            idsIn,
            executeCallData,
            payable(this),
            true
        );

        for (uint i; i < qty; i++) {
            assertEq(nft.ownerOf(idsIn[i]), address(vtoken));
        }
    }

    // MarketplaceZap#swap721
    function test_swap721_RevertsForNonOwnerIfPaused() external {
        marketplaceZap.pause(true);

        uint256[] memory idsIn;
        uint256[] memory idsOut;

        hoax(makeAddr("nonOwner"));
        vm.expectRevert(MarketplaceUniversalRouterZap.ZapPaused.selector);
        marketplaceZap.swap721(VAULT_ID, idsIn, idsOut, payable(this));
    }

    function test_swap721_Success() external {
        _mintPositionWithTwap(currentNFTPrice);

        uint256 qty = 5;
        (, uint256[] memory idsOut) = _mintVToken(qty);

        uint256[] memory idsIn = nft.mint(qty);

        // accounting for premium
        uint256 exactETHPaid = ((vtoken.targetSwapFee() +
            vaultFactory.premiumMax()) *
            qty *
            currentNFTPrice) / 1 ether;
        uint256 expectedETHPaid = _valueWithError(exactETHPaid);

        uint256 prevETHBal = address(this).balance;

        nft.setApprovalForAll(address(marketplaceZap), true);
        // double ETH value here to check if refund working as well
        marketplaceZap.swap721{value: expectedETHPaid * 2}(
            VAULT_ID,
            idsIn,
            idsOut,
            payable(this)
        );

        uint256 ethPaid = prevETHBal - address(this).balance;
        assertGt(ethPaid, expectedETHPaid);
        assertLe(ethPaid, exactETHPaid);

        for (uint i; i < qty; i++) {
            assertEq(nft.ownerOf(idsIn[i]), address(vtoken));
            assertEq(nft.ownerOf(idsOut[i]), address(this));
        }
    }

    // MarketplaceZap#buyNFTsWithETH
    function test_buyNFTs_RevertsForNonOwnerIfPaused() external {
        marketplaceZap.pause(true);

        uint256[] memory idsOut;
        bytes memory executeCallData;

        hoax(makeAddr("nonOwner"));
        vm.expectRevert(MarketplaceUniversalRouterZap.ZapPaused.selector);
        marketplaceZap.buyNFTsWithETH(
            VAULT_ID,
            idsOut,
            executeCallData,
            payable(this),
            true
        );
    }

    function test_buyNFTsWithETH_721_Success() external {
        _mintPositionWithTwap(currentNFTPrice);

        uint256 qty = 5;
        (, uint256[] memory idsOut) = _mintVToken(qty);

        uint256 exactETHFees = ((vtoken.targetRedeemFee() +
            vaultFactory.premiumMax()) *
            qty *
            currentNFTPrice) / 1 ether;
        uint256 expectedETHFees = _valueWithError(exactETHFees);

        (uint256 wethRequired, , , ) = quoter.quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(vtoken),
                amount: qty * 1 ether,
                fee: DEFAULT_FEE_TIER,
                sqrtPriceLimitX96: 0
            })
        );
        bytes memory executeCallData = abi.encodeWithSelector(
            MockUniversalRouter.execute.selector,
            address(weth),
            wethRequired,
            address(vtoken)
        );

        uint256 prevETHBal = address(this).balance;

        // double ETH value here to check if refund working as well
        marketplaceZap.buyNFTsWithETH{
            value: expectedETHFees * 2 + wethRequired
        }(VAULT_ID, idsOut, executeCallData, payable(this), true);

        uint256 ethPaid = prevETHBal - address(this).balance;
        assertGt(ethPaid, expectedETHFees + wethRequired);
        assertLe(ethPaid, exactETHFees + wethRequired);

        for (uint i; i < qty; i++) {
            assertEq(nft.ownerOf(idsOut[i]), address(this));
        }
    }

    // MarketplaceZap#buyNFTsWithERC20

    function test_buyNFTsWithERC20_721_Success() external {
        _mintPositionWithTwap(currentNFTPrice);
        INFTXVault token = _mintPositionERC20();

        uint256 qty = 5;
        (, uint256[] memory idsOut) = _mintVToken(qty);

        uint256 exactETHFees = ((vtoken.targetRedeemFee() +
            vaultFactory.premiumMax()) *
            qty *
            currentNFTPrice) / 1 ether;
        // uint256 expectedETHFees = _valueWithError(exactETHFees);

        (uint256 wethRequiredForVTokens, , , ) = quoter.quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(vtoken),
                amount: qty * 1 ether,
                fee: DEFAULT_FEE_TIER,
                sqrtPriceLimitX96: 0
            })
        );
        (uint256 tokenInRequiredForETHFees, , , ) = quoter
            .quoteExactOutputSingle(
                IQuoterV2.QuoteExactOutputSingleParams({
                    tokenIn: address(token),
                    tokenOut: address(weth),
                    amount: (wethRequiredForVTokens + exactETHFees),
                    fee: DEFAULT_FEE_TIER,
                    sqrtPriceLimitX96: 0
                })
            );
        bytes memory executeToWETHCallData = abi.encodeWithSelector(
            MockUniversalRouter.execute.selector,
            address(token),
            tokenInRequiredForETHFees,
            address(weth)
        );
        bytes memory executeToVTokenCallData = abi.encodeWithSelector(
            MockUniversalRouter.execute.selector,
            address(weth),
            wethRequiredForVTokens,
            address(vtoken)
        );

        // get tokenIn
        uint256[] memory tokenIds = nft.mint(
            tokenInRequiredForETHFees / 1 ether + 1
        );
        nft.setApprovalForAll(address(token), true);
        uint256[] memory amounts = new uint256[](0);
        token.mint(tokenIds, amounts) * 1 ether;

        token.approve(address(marketplaceZap), tokenInRequiredForETHFees);
        marketplaceZap.buyNFTsWithERC20(
            MarketplaceUniversalRouterZap.BuyNFTsWithERC20Params({
                tokenIn: IERC20(address(token)),
                amountIn: tokenInRequiredForETHFees,
                vaultId: VAULT_ID,
                idsOut: idsOut,
                executeToWETHCallData: executeToWETHCallData,
                executeToVTokenCallData: executeToVTokenCallData,
                to: payable(this),
                deductRoyalty: true
            })
        );

        for (uint i; i < qty; i++) {
            assertEq(nft.ownerOf(idsOut[i]), address(this));
        }
    }

    function test_buyNFTsWithERC20WithPermit2_721_Success() external {
        _mintPositionWithTwap(currentNFTPrice);
        INFTXVault token = _mintPositionERC20();

        uint256 qty = 5;
        (, uint256[] memory idsOut) = _mintVToken(qty);

        uint256 exactETHFees = ((vtoken.targetRedeemFee() +
            vaultFactory.premiumMax()) *
            qty *
            currentNFTPrice) / 1 ether;
        // uint256 expectedETHFees = _valueWithError(exactETHFees);

        (uint256 wethRequiredForVTokens, , , ) = quoter.quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(vtoken),
                amount: qty * 1 ether,
                fee: DEFAULT_FEE_TIER,
                sqrtPriceLimitX96: 0
            })
        );
        (uint256 tokenInRequiredForETHFees, , , ) = quoter
            .quoteExactOutputSingle(
                IQuoterV2.QuoteExactOutputSingleParams({
                    tokenIn: address(token),
                    tokenOut: address(weth),
                    amount: (wethRequiredForVTokens + exactETHFees),
                    fee: DEFAULT_FEE_TIER,
                    sqrtPriceLimitX96: 0
                })
            );
        bytes memory executeToWETHCallData = abi.encodeWithSelector(
            MockUniversalRouter.execute.selector,
            address(token),
            tokenInRequiredForETHFees,
            address(weth)
        );
        bytes memory executeToVTokenCallData = abi.encodeWithSelector(
            MockUniversalRouter.execute.selector,
            address(weth),
            wethRequiredForVTokens,
            address(vtoken)
        );

        startHoax(from);

        // get tokenIn
        uint256[] memory tokenIds = nft.mint(
            tokenInRequiredForETHFees / 1 ether + 1
        );
        nft.setApprovalForAll(address(token), true);
        uint256[] memory amounts = new uint256[](0);
        token.mint(tokenIds, amounts) * 1 ether;

        bytes memory encodedPermit2 = _getEncodedPermit2(
            address(token),
            tokenInRequiredForETHFees,
            address(marketplaceZap)
        );

        marketplaceZap.buyNFTsWithERC20WithPermit2(
            MarketplaceUniversalRouterZap.BuyNFTsWithERC20Params({
                tokenIn: IERC20(address(token)),
                amountIn: tokenInRequiredForETHFees,
                vaultId: VAULT_ID,
                idsOut: idsOut,
                executeToWETHCallData: executeToWETHCallData,
                executeToVTokenCallData: executeToVTokenCallData,
                to: payable(from),
                deductRoyalty: true
            }),
            encodedPermit2
        );

        for (uint i; i < qty; i++) {
            assertEq(nft.ownerOf(idsOut[i]), address(from));
        }
    }

    function _mintPositionERC20() internal returns (INFTXVault token) {
        int24 tickLower;
        int24 tickUpper;
        uint256 qty = 150;

        uint256 vaultId2 = vaultFactory.createVault(
            "TEST2",
            "TST2",
            address(nft),
            false,
            true
        );
        token = INFTXVault(vaultFactory.vault(vaultId2));
        uint256 amount;
        {
            uint256[] memory tokenIds = nft.mint(qty);
            nft.setApprovalForAll(address(token), true);
            uint256[] memory amounts = new uint256[](0);
            amount = token.mint(tokenIds, amounts) * 1 ether;
        }

        uint256 currentTokenPrice = 3 ether;
        uint256 lowerTokenPrice = 2 ether;
        uint256 upperTokenPrice = 4 ether;

        uint160 currentSqrtP;
        uint256 tickDistance = _getTickDistance(DEFAULT_FEE_TIER);

        if (nftxRouter.isVToken0(address(token))) {
            currentSqrtP = Helpers.encodeSqrtRatioX96(
                currentTokenPrice,
                1 ether
            );
            // price = amount1 / amount0 = 1.0001^tick => tick ∝ price
            tickLower = Helpers.getTickForAmounts(
                lowerTokenPrice,
                1 ether,
                tickDistance
            );
            tickUpper = Helpers.getTickForAmounts(
                upperTokenPrice,
                1 ether,
                tickDistance
            );
        } else {
            currentSqrtP = Helpers.encodeSqrtRatioX96(
                1 ether,
                currentTokenPrice
            );
            tickLower = Helpers.getTickForAmounts(
                1 ether,
                upperTokenPrice,
                tickDistance
            );
            tickUpper = Helpers.getTickForAmounts(
                1 ether,
                lowerTokenPrice,
                tickDistance
            );
        }

        token.approve(address(nftxRouter), type(uint256).max);
        uint256[] memory nftIds;
        nftxRouter.addLiquidity{value: (amount * 100 ether) / 1 ether}(
            INFTXRouter.AddLiquidityParams({
                vaultId: vaultId2,
                vTokensAmount: amount,
                nftIds: nftIds,
                nftAmounts: emptyIds,
                is1155: false,
                tickLower: tickLower,
                tickUpper: tickUpper,
                fee: DEFAULT_FEE_TIER,
                sqrtPriceX96: currentSqrtP,
                deadline: block.timestamp
            })
        );
    }
}
