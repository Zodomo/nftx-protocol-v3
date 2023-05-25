// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./util/OwnableUpgradeable.sol";
import "./util/ReentrancyGuardUpgradeable.sol";
import "./util/EnumerableSetUpgradeable.sol";
import "./token/ERC20FlashMintUpgradeable.sol";
import "./token/ERC721SafeHolderUpgradeable.sol";
import "./token/ERC1155SafeHolderUpgradeable.sol";
import "./token/IERC1155Upgradeable.sol";
import "./token/IERC721Upgradeable.sol";
import "./interface/INFTXVault.sol";
import "./interface/INFTXEligibilityManager.sol";
import "./interface/INFTXFeeDistributor.sol";
import {ExponentialPremium} from "./lib/ExponentialPremium.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {IWETH9} from "@uni-periphery/interfaces/external/IWETH9.sol";
import {INFTXFeeDistributorV3} from "@src/interfaces/INFTXFeeDistributorV3.sol";
import {INFTXRouter} from "@src/interfaces/INFTXRouter.sol";

// Authors: @0xKiwi_, @alexgausman and @apoorvlathey

contract NFTXVaultUpgradeable is
    OwnableUpgradeable,
    ERC20FlashMintUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC721SafeHolderUpgradeable,
    ERC1155SafeHolderUpgradeable,
    INFTXVault
{
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;

    uint256 constant base = 10 ** 18;

    uint256 public override vaultId;
    address public override manager;
    address public override assetAddress;
    INFTXVaultFactory public override vaultFactory;
    INFTXEligibility public override eligibilityStorage;

    uint256 UNUSED_FEE4;
    uint256 private UNUSED_FEE1;
    uint256 private UNUSED_FEE2;
    uint256 private UNUSED_FEE3;

    bool public override is1155;
    bool public override allowAllItems;
    bool public override enableMint;
    bool private UNUSED_FEE5;
    bool private UNUSED_FEE6;

    EnumerableSetUpgradeable.UintSet holdings;
    mapping(uint256 => uint256) quantity1155;

    bool private UNUSED_FEE7;
    bool private UNUSED_FEE8;

    // tokenId => info
    mapping(uint256 => uint256) public tokenDepositedAt;

    // =============================================================
    //                           INIT
    // =============================================================

    function __NFTXVault_init(
        string memory _name,
        string memory _symbol,
        address _assetAddress,
        bool _is1155,
        bool _allowAllItems
    ) public virtual override initializer {
        __Ownable_init();
        __ERC20_init(_name, _symbol);
        require(_assetAddress != address(0), "Asset != address(0)");
        assetAddress = _assetAddress;
        vaultFactory = INFTXVaultFactory(msg.sender);
        vaultId = vaultFactory.numVaults();
        is1155 = _is1155;
        allowAllItems = _allowAllItems;
        emit VaultInit(vaultId, _assetAddress, _is1155, _allowAllItems);
        setVaultFeatures(
            true /*enableMint*/,
            true /*enableTargetRedeem*/,
            true /*enableTargetSwap*/
        );
    }

    // =============================================================
    //                     PUBLIC / EXTERNAL WRITE
    // =============================================================

    function mint(
        uint256[] calldata tokenIds,
        uint256[] calldata amounts /* ignored for ERC721 vaults */
    ) external payable virtual override returns (uint256) {
        return mintTo(tokenIds, amounts, msg.sender);
    }

    function mintTo(
        uint256[] memory tokenIds,
        uint256[] memory amounts /* ignored for ERC721 vaults */,
        address to
    ) public payable virtual override nonReentrant returns (uint256) {
        onlyOwnerIfPaused(1);
        require(enableMint, "Minting not enabled");
        // Take the NFTs.
        uint256 count = _receiveNFTs(tokenIds, amounts);

        // Mint to the user.
        _mint(to, base * count);

        uint256 totalVTokenFee = mintFee() * count;
        uint256 ethFees = _chargeAndDistributeFees(totalVTokenFee, msg.value);

        _refundETH(msg.value, ethFees);

        emit Minted(tokenIds, amounts, to);
        return count;
    }

    function redeem(
        uint256[] calldata specificIds
    ) external payable virtual override {
        return redeemTo(specificIds, msg.sender);
    }

    function redeemTo(
        uint256[] memory specificIds,
        address to
    ) public payable virtual override nonReentrant {
        onlyOwnerIfPaused(2);
        uint256 count = specificIds.length;

        // We burn all from sender and mint to fee receiver to reduce costs.
        _burn(msg.sender, base * count);

        (, uint256 _targetRedeemFee, ) = vaultFees();
        uint256 totalVTokenFee = (_targetRedeemFee * count);

        // Withdraw from vault.
        uint256 vTokenPremium = _withdrawNFTsTo(specificIds, to);

        uint256 ethFees = _chargeAndDistributeFees(
            totalVTokenFee + vTokenPremium,
            msg.value
        );

        _refundETH(msg.value, ethFees);

        emit Redeemed(specificIds, to);
    }

    function swap(
        uint256[] calldata tokenIds,
        uint256[] calldata amounts /* ignored for ERC721 vaults */,
        uint256[] calldata specificIds
    ) external payable virtual override {
        return swapTo(tokenIds, amounts, specificIds, msg.sender);
    }

    function swapTo(
        uint256[] memory tokenIds,
        uint256[] memory amounts /* ignored for ERC721 vaults */,
        uint256[] memory specificIds,
        address to
    ) public payable virtual override nonReentrant {
        onlyOwnerIfPaused(3);
        uint256 count;
        if (is1155) {
            for (uint256 i; i < tokenIds.length; ++i) {
                uint256 amount = amounts[i];
                require(amount != 0, "NFTXVault: transferring < 1");
                count += amount;
            }
        } else {
            count = tokenIds.length;
        }

        require(count == specificIds.length, "NFTXVault: Random swap disabled");

        (, , uint256 _targetSwapFee) = vaultFees();
        uint256 totalVTokenFee = (_targetSwapFee * specificIds.length);

        // Give the NFTs first, so the user wont get the same thing back, just to be nice.
        uint256 vTokenPremium = _withdrawNFTsTo(specificIds, to);

        uint256 ethFees = _chargeAndDistributeFees(
            totalVTokenFee + vTokenPremium,
            msg.value
        );

        _receiveNFTs(tokenIds, amounts);

        _refundETH(msg.value, ethFees);

        emit Swapped(tokenIds, amounts, specificIds, to);
    }

    function flashLoan(
        IERC3156FlashBorrowerUpgradeable receiver,
        address token,
        uint256 amount,
        bytes memory data
    ) public virtual override returns (bool) {
        onlyOwnerIfPaused(4);
        return super.flashLoan(receiver, token, amount, data);
    }

    // =============================================================
    //                     ONLY PRIVILEGED WRITE
    // =============================================================

    function finalizeVault() external virtual override {
        setManager(address(0));
    }

    // Added in v1.0.3.
    function setVaultMetadata(
        string calldata name_,
        string calldata symbol_
    ) external virtual override {
        onlyPrivileged();
        _setMetadata(name_, symbol_);
    }

    function setVaultFeatures(
        bool _enableMint,
        bool _enableTargetRedeem,
        bool _enableTargetSwap
    ) public virtual override {
        onlyPrivileged();
        enableMint = _enableMint;

        emit EnableMintUpdated(_enableMint);
        emit EnableTargetRedeemUpdated(_enableTargetRedeem);
        emit EnableTargetSwapUpdated(_enableTargetSwap);
    }

    function setFees(
        uint256 _mintFee,
        uint256 _targetRedeemFee,
        uint256 _targetSwapFee
    ) public virtual override {
        onlyPrivileged();
        vaultFactory.setVaultFees(
            vaultId,
            _mintFee,
            _targetRedeemFee,
            _targetSwapFee
        );
    }

    function disableVaultFees() public virtual override {
        onlyPrivileged();
        vaultFactory.disableVaultFees(vaultId);
    }

    // This function allows for an easy setup of any eligibility module contract from the EligibilityManager.
    // It takes in ABI encoded parameters for the desired module. This is to make sure they can all follow
    // a similar interface.
    function deployEligibilityStorage(
        uint256 moduleIndex,
        bytes calldata initData
    ) external virtual override returns (address) {
        onlyPrivileged();
        require(
            address(eligibilityStorage) == address(0),
            "NFTXVault: eligibility already set"
        );
        INFTXEligibilityManager eligManager = INFTXEligibilityManager(
            vaultFactory.eligibilityManager()
        );
        address _eligibility = eligManager.deployEligibility(
            moduleIndex,
            initData
        );
        eligibilityStorage = INFTXEligibility(_eligibility);
        // Toggle this to let the contract know to check eligibility now.
        allowAllItems = false;
        emit EligibilityDeployed(moduleIndex, _eligibility);
        return _eligibility;
    }

    // // This function allows for the manager to set their own arbitrary eligibility contract.
    // // Once eligiblity is set, it cannot be unset or changed.
    // Disabled for launch.
    // function setEligibilityStorage(address _newEligibility) public virtual {
    //     onlyPrivileged();
    //     require(
    //         address(eligibilityStorage) == address(0),
    //         "NFTXVault: eligibility already set"
    //     );
    //     eligibilityStorage = INFTXEligibility(_newEligibility);
    //     // Toggle this to let the contract know to check eligibility now.
    //     allowAllItems = false;
    //     emit CustomEligibilityDeployed(address(_newEligibility));
    // }

    // The manager has control over options like fees and features
    function setManager(address _manager) public virtual override {
        onlyPrivileged();
        manager = _manager;
        emit ManagerSet(_manager);
    }

    // =============================================================
    //                     PUBLIC / EXTERNAL VIEW
    // =============================================================

    function mintFee() public view virtual override returns (uint256) {
        (uint256 _mintFee, , ) = vaultFactory.vaultFees(vaultId);
        return _mintFee;
    }

    function targetRedeemFee() public view virtual override returns (uint256) {
        (, uint256 _targetRedeemFee, ) = vaultFactory.vaultFees(vaultId);
        return _targetRedeemFee;
    }

    function targetSwapFee() public view virtual override returns (uint256) {
        (, , uint256 _targetSwapFee) = vaultFactory.vaultFees(vaultId);
        return _targetSwapFee;
    }

    function vaultFees()
        public
        view
        virtual
        override
        returns (uint256, uint256, uint256)
    {
        return vaultFactory.vaultFees(vaultId);
    }

    function allValidNFTs(
        uint256[] memory tokenIds
    ) public view virtual override returns (bool) {
        if (allowAllItems) {
            return true;
        }

        INFTXEligibility _eligibilityStorage = eligibilityStorage;
        if (address(_eligibilityStorage) == address(0)) {
            return false;
        }
        return _eligibilityStorage.checkAllEligible(tokenIds);
    }

    function nftIdAt(
        uint256 holdingsIndex
    ) external view virtual override returns (uint256) {
        return holdings.at(holdingsIndex);
    }

    // Added in v1.0.3.
    function allHoldings()
        external
        view
        virtual
        override
        returns (uint256[] memory)
    {
        uint256 len = holdings.length();
        uint256[] memory idArray = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            idArray[i] = holdings.at(i);
        }
        return idArray;
    }

    // Added in v1.0.3.
    function totalHoldings() external view virtual override returns (uint256) {
        return holdings.length();
    }

    // Added in v1.0.3.
    function version() external pure returns (string memory) {
        return "v1.0.6";
    }

    function getVTokenPremium(
        uint256 tokenId
    ) public view override returns (uint256) {
        return
            ExponentialPremium.getPremium(
                tokenDepositedAt[tokenId],
                vaultFactory.premiumMax(),
                vaultFactory.premiumDuration()
            );
    }

    function vTokenToETH(
        uint256 vTokenAmount
    ) external view override returns (uint256 ethAmount) {
        (ethAmount, ) = _vTokenToETH(vaultFactory, vTokenAmount);
    }

    // =============================================================
    //                        INTERNAL HELPERS
    // =============================================================

    // We set a hook to the eligibility module (if it exists) after redeems in case anything needs to be modified.
    function _afterRedeemHook(uint256[] memory tokenIds) internal virtual {
        INFTXEligibility _eligibilityStorage = eligibilityStorage;
        if (address(_eligibilityStorage) == address(0)) {
            return;
        }
        _eligibilityStorage.afterRedeemHook(tokenIds);
    }

    function _receiveNFTs(
        uint256[] memory tokenIds,
        uint256[] memory amounts
    ) internal virtual returns (uint256) {
        require(allValidNFTs(tokenIds), "NFTXVault: not eligible");
        uint256 length = tokenIds.length;
        if (is1155) {
            // This is technically a check, so placing it before the effect.
            IERC1155Upgradeable(assetAddress).safeBatchTransferFrom(
                msg.sender,
                address(this),
                tokenIds,
                amounts,
                ""
            );

            uint256 count;
            for (uint256 i; i < length; ++i) {
                uint256 tokenId = tokenIds[i];
                uint256 amount = amounts[i];
                require(amount != 0, "NFTXVault: transferring < 1");
                if (quantity1155[tokenId] == 0) {
                    holdings.add(tokenId);
                }
                quantity1155[tokenId] += amount;
                count += amount;

                // TODO: calculate premium for ERC1155
                // tokenDepositInfo[tokenId] = TokenDepositInfo({
                //     depositor: msg.sender,
                //     depositedAt: block.timestamp
                // });
            }
            return count;
        } else {
            address _assetAddress = assetAddress;
            for (uint256 i; i < length; ++i) {
                uint256 tokenId = tokenIds[i];
                // We may already own the NFT here so we check in order:
                // Does the vault own it?
                //   - If so, check if its in holdings list
                //      - If so, we reject. This means the NFT has already been claimed for.
                //      - If not, it means we have not yet accounted for this NFT, so we continue.
                //   -If not, we "pull" it from the msg.sender and add to holdings.
                transferFromERC721(_assetAddress, tokenId);
                holdings.add(tokenId);
                tokenDepositedAt[tokenId] = block.timestamp;
            }
            return length;
        }
    }

    function _withdrawNFTsTo(
        uint256[] memory specificIds,
        address to
    ) internal virtual returns (uint256 vTokenPremium) {
        bool _is1155 = is1155;
        address _assetAddress = assetAddress;

        for (uint256 i; i < specificIds.length; ++i) {
            // This will always be fine considering the validations made above.
            uint256 tokenId = specificIds[i];

            if (_is1155) {
                quantity1155[tokenId] -= 1;
                if (quantity1155[tokenId] == 0) {
                    holdings.remove(tokenId);
                }

                IERC1155Upgradeable(_assetAddress).safeTransferFrom(
                    address(this),
                    to,
                    tokenId,
                    1,
                    ""
                );
                // TODO: vTokenPremium for ERC1155
            } else {
                vTokenPremium += getVTokenPremium(tokenId);
                holdings.remove(tokenId);
                transferERC721(_assetAddress, to, tokenId);
            }
        }
        _afterRedeemHook(specificIds);
    }

    /// @dev Uses TWAP to calculate fees `ethAmount` corresponding to the given `vTokenAmount`
    /// Returns 0 if pool doesn't exist or sender is excluded from fees.
    function _chargeAndDistributeFees(
        uint256 vTokenFeeAmount,
        uint256 ethReceived
    ) internal returns (uint256 ethAmount) {
        // cache
        INFTXVaultFactory _vaultFactory = vaultFactory;

        if (_vaultFactory.excludedFromFees(msg.sender)) {
            return 0;
        }

        INFTXFeeDistributorV3 feeDistributor;
        (ethAmount, feeDistributor) = _vTokenToETH(
            _vaultFactory,
            vTokenFeeAmount
        );

        if (ethReceived < ethAmount) revert InsufficientETHSent();

        if (ethAmount > 0) {
            IWETH9 weth = IWETH9(address(feeDistributor.WETH()));
            weth.deposit{value: ethAmount}();
            weth.transfer(address(feeDistributor), ethAmount);
            feeDistributor.distribute(vaultId);
        }
    }

    function _getTwapX96(
        address pool
    ) internal view returns (uint256 priceX96) {
        // cache
        uint32 _twapInterval = vaultFactory.twapInterval();

        // FIXME: avoid using obeservationIndex here. TWAP duration is going to be few minutes so fees can be ignored for such small duration.
        // ... setting cardinalityNext during deployment is quite costly, instead that cost can be shared with swappers until maxCardinalityNext is achieved
        // ... for 30 mins twapInterval, that's 145 swaps
        // ... only do this for DEFAULT_FEE_TIER
        (, , uint16 observationIndex, , , , ) = IUniswapV3Pool(pool).slot0();
        (uint32 lastObsTimestamp, , , bool initialized) = IUniswapV3Pool(pool)
            .observations(observationIndex);
        if (!initialized) {
            return 0;
        }

        // secondsAgos[0] (from [before]) -> secondsAgos[1] (to [now])
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[1] = 0;
        if (block.timestamp - _twapInterval < lastObsTimestamp) {
            secondsAgos[0] = uint32(block.timestamp) - lastObsTimestamp;
        } else {
            secondsAgos[0] = _twapInterval;
        }
        if (secondsAgos[0] == 0) {
            return 0;
        }

        (int56[] memory tickCumulatives, ) = IUniswapV3Pool(pool).observe(
            secondsAgos
        );

        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(
            int24(
                (tickCumulatives[1] - tickCumulatives[0]) /
                    int56(int32(secondsAgos[0]))
            )
        );
        priceX96 = FullMath.mulDiv(
            sqrtPriceX96,
            sqrtPriceX96,
            FixedPoint96.Q96
        );
    }

    function _vTokenToETH(
        INFTXVaultFactory _vaultFactory,
        uint256 vTokenAmount
    )
        internal
        view
        returns (uint256 ethAmount, INFTXFeeDistributorV3 feeDistributor)
    {
        feeDistributor = INFTXFeeDistributorV3(_vaultFactory.feeDistributor());
        INFTXRouter nftxRouter = INFTXRouter(feeDistributor.nftxRouter());

        (address pool, bool exists) = nftxRouter.getPoolExists(
            address(this),
            feeDistributor.REWARD_FEE_TIER()
        );
        if (!exists) {
            return (0, feeDistributor);
        }

        // price = amount1 / amount0
        // priceX96 = price * 2^96
        uint256 priceX96 = _getTwapX96(pool);
        if (priceX96 == 0) return (0, feeDistributor);

        bool isVToken0 = nftxRouter.isVToken0(address(this));
        if (isVToken0) {
            ethAmount = FullMath.mulDiv(
                vTokenAmount,
                priceX96,
                FixedPoint96.Q96
            );
        } else {
            ethAmount = FullMath.mulDiv(
                vTokenAmount,
                FixedPoint96.Q96,
                priceX96
            );
        }
    }

    /// @dev Must satisfy ethReceived >= ethFees
    function _refundETH(uint256 ethReceived, uint256 ethFees) internal {
        uint256 ethRefund = ethReceived - ethFees;
        if (ethRefund > 0) {
            (bool success, ) = payable(msg.sender).call{value: ethRefund}("");
            if (!success) revert UnableToRefundETH();
        }
    }

    function transferERC721(
        address assetAddr,
        address to,
        uint256 tokenId
    ) internal virtual {
        address kitties = 0x06012c8cf97BEaD5deAe237070F9587f8E7A266d;
        address punks = 0xb47e3cd837dDF8e4c57F05d70Ab865de6e193BBB;
        bytes memory data;
        if (assetAddr == kitties) {
            // Changed in v1.0.4.
            data = abi.encodeWithSignature(
                "transfer(address,uint256)",
                to,
                tokenId
            );
        } else if (assetAddr == punks) {
            // CryptoPunks.
            data = abi.encodeWithSignature(
                "transferPunk(address,uint256)",
                to,
                tokenId
            );
        } else {
            // Default.
            data = abi.encodeWithSignature(
                "safeTransferFrom(address,address,uint256)",
                address(this),
                to,
                tokenId
            );
        }
        (bool success, bytes memory returnData) = address(assetAddr).call(data);
        require(success, string(returnData));
    }

    function transferFromERC721(
        address assetAddr,
        uint256 tokenId
    ) internal virtual {
        address kitties = 0x06012c8cf97BEaD5deAe237070F9587f8E7A266d;
        address punks = 0xb47e3cd837dDF8e4c57F05d70Ab865de6e193BBB;
        bytes memory data;
        if (assetAddr == kitties) {
            // Cryptokitties.
            data = abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                msg.sender,
                address(this),
                tokenId
            );
        } else if (assetAddr == punks) {
            // CryptoPunks.
            // Fix here for frontrun attack. Added in v1.0.2.
            bytes memory punkIndexToAddress = abi.encodeWithSignature(
                "punkIndexToAddress(uint256)",
                tokenId
            );
            (bool checkSuccess, bytes memory result) = address(assetAddr)
                .staticcall(punkIndexToAddress);
            address nftOwner = abi.decode(result, (address));
            require(
                checkSuccess && nftOwner == msg.sender,
                "Not the NFT owner"
            );
            data = abi.encodeWithSignature("buyPunk(uint256)", tokenId);
        } else {
            // Default.
            // Allow other contracts to "push" into the vault, safely.
            // If we already have the token requested, make sure we don't have it in the list to prevent duplicate minting.
            if (
                IERC721Upgradeable(assetAddress).ownerOf(tokenId) ==
                address(this)
            ) {
                require(
                    !holdings.contains(tokenId),
                    "Trying to use an owned NFT"
                );
                return;
            } else {
                data = abi.encodeWithSignature(
                    "safeTransferFrom(address,address,uint256)",
                    msg.sender,
                    address(this),
                    tokenId
                );
            }
        }
        (bool success, bytes memory resultData) = address(assetAddr).call(data);
        require(success, string(resultData));
    }

    function onlyPrivileged() internal view {
        if (manager == address(0)) {
            require(msg.sender == owner(), "Not owner");
        } else {
            require(msg.sender == manager, "Not manager");
        }
    }

    function onlyOwnerIfPaused(uint256 lockId) internal view {
        require(
            !vaultFactory.isLocked(lockId) || msg.sender == owner(),
            "Paused"
        );
    }
}
