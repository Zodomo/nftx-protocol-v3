// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ERC721HolderUpgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import {ERC1155HolderUpgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import {ERC20FlashMintUpgradeable, IERC3156FlashBorrowerUpgradeable} from "@src/custom/tokens/ERC20/ERC20FlashMintUpgradeable.sol";

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {TransferLib} from "@src/lib/TransferLib.sol";
import {FixedPoint96} from "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import {ExponentialPremium} from "@src/lib/ExponentialPremium.sol";
import {SafeERC20Upgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {EnumerableSetUpgradeable} from "@openzeppelin-upgradeable/contracts/utils/structs/EnumerableSetUpgradeable.sol";

import {IWETH9} from "@uni-periphery/interfaces/external/IWETH9.sol";
import {INFTXRouter} from "@src/interfaces/INFTXRouter.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INFTXEligibility} from "@src/interfaces/INFTXEligibility.sol";
import {IERC20Upgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";
import {IERC721Upgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC721/IERC721Upgradeable.sol";
import {INFTXVaultFactoryV3} from "@src/interfaces/INFTXVaultFactoryV3.sol";
import {IERC1155Upgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC1155/IERC1155Upgradeable.sol";
import {INFTXFeeDistributorV3} from "@src/interfaces/INFTXFeeDistributorV3.sol";
import {INFTXEligibilityManager} from "@src/interfaces/INFTXEligibilityManager.sol";
import {IUniswapV3PoolDerivedState} from "@uniswap/v3-core/contracts/interfaces/pool/IUniswapV3PoolDerivedState.sol";

import {INFTXVaultV3} from "@src/interfaces/INFTXVaultV3.sol";

// Authors: @0xKiwi_, @alexgausman and @apoorvlathey

contract NFTXVaultUpgradeableV3 is
    INFTXVaultV3,
    OwnableUpgradeable,
    ERC20FlashMintUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC721HolderUpgradeable,
    ERC1155HolderUpgradeable
{
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // =============================================================
    //                           CONSTANTS
    // =============================================================

    uint256 constant BASE = 10 ** 18;
    IWETH9 public immutable override WETH;
    address CRYPTO_PUNKS = 0xb47e3cd837dDF8e4c57F05d70Ab865de6e193BBB;
    address CRYPTO_KITTIES = 0x06012c8cf97BEaD5deAe237070F9587f8E7A266d;

    // only set during initialization

    address public override assetAddress;
    INFTXVaultFactoryV3 public override vaultFactory;
    uint256 public override vaultId;
    bool public override is1155;

    // =============================================================
    //                            VARIABLES
    // =============================================================

    address public override manager;

    INFTXEligibility public override eligibilityStorage;

    bool public override allowAllItems;
    bool public override enableMint;

    EnumerableSetUpgradeable.UintSet internal _holdings;
    // tokenId => qty
    mapping(uint256 => uint256) internal _quantity1155;

    // tokenId => info
    mapping(uint256 => TokenDepositInfo) public override tokenDepositInfo;

    /**
     * For ERC1155 deposits, per TokenId:
     *
     *                          pointerIndex1155
     *                                |
     *                                V
     * [{qty: 0, depositor: A}, {qty: 5, depositor: B}, {qty: 10, depositor: C}, ...]
     *
     * New deposits are pushed to the end of array, and the oldest remaining deposit is used while withdrawing, hence following FIFO.
     */

    // tokenId => info[]
    mapping(uint256 => DepositInfo1155[]) public override depositInfo1155;
    // tokenId => pointerIndex
    mapping(uint256 => uint256) public override pointerIndex1155;

    // =============================================================
    //                           INIT
    // =============================================================

    constructor(IWETH9 WETH_) {
        WETH = WETH_;
    }

    function __NFTXVault_init(
        string memory _name,
        string memory _symbol,
        address _assetAddress,
        bool _is1155,
        bool _allowAllItems
    ) public override initializer {
        __Ownable_init();
        __ERC20_init(_name, _symbol);

        if (_assetAddress == address(0)) revert ZeroAddress();
        assetAddress = _assetAddress;
        vaultFactory = INFTXVaultFactoryV3(msg.sender);
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

    // TODO: add NATSPEC
    function mint(
        uint256[] calldata tokenIds,
        uint256[] calldata amounts /* ignored for ERC721 vaults */
    ) external payable override returns (uint256 vTokensMinted) {
        return mintTo(tokenIds, amounts, msg.sender);
    }

    // TODO: add NATSPEC
    function mintTo(
        uint256[] calldata tokenIds,
        uint256[] calldata amounts /* ignored for ERC721 vaults */,
        address to
    ) public payable override nonReentrant returns (uint256 vTokensMinted) {
        _onlyOwnerIfPaused(1);
        if (!enableMint) revert MintingDisabled();

        // Take the NFTs.
        uint256 nftCount = _receiveNFTs(tokenIds, amounts);
        vTokensMinted = BASE * nftCount;

        // Mint to the user.
        _mint(to, vTokensMinted);

        (uint256 mintFee, , ) = vaultFees();
        uint256 totalVTokenFee = mintFee * nftCount;
        uint256 ethFees = _chargeAndDistributeFees(totalVTokenFee, msg.value);

        _refundETH(msg.value, ethFees);

        emit Minted(tokenIds, amounts, to);
    }

    // TODO: add NATSPEC
    function redeem(
        uint256[] calldata idsOut,
        uint256 wethAmount,
        bool forceFees
    ) external payable override returns (uint256 ethFees) {
        return redeemTo(idsOut, msg.sender, wethAmount, forceFees);
    }

    // TODO: add NATSPEC
    function redeemTo(
        uint256[] calldata idsOut,
        address to,
        uint256 wethAmount,
        bool forceFees
    ) public payable override nonReentrant returns (uint256 ethFees) {
        _onlyOwnerIfPaused(2);

        uint256 ethOrWethAmt;
        if (wethAmount > 0) {
            require(msg.value == 0);

            ethOrWethAmt = wethAmount;
        } else {
            ethOrWethAmt = msg.value;
        }

        uint256 count = idsOut.length;

        // We burn all from sender and mint to fee receiver to reduce costs.
        _burn(msg.sender, BASE * count);

        (, uint256 redeemFee, ) = vaultFees();
        uint256 totalVaultFee = (redeemFee * count);

        // Withdraw from vault.
        (
            uint256 netVTokenPremium,
            uint256[] memory vTokenPremiums,
            address[] memory depositors
        ) = _withdrawNFTsTo(idsOut, to, forceFees);

        ethFees = _chargeAndDistributeFees(
            ethOrWethAmt,
            msg.value > 0,
            totalVaultFee,
            netVTokenPremium,
            vTokenPremiums,
            depositors,
            forceFees
        );

        if (msg.value > 0) {
            _refundETH(msg.value, ethFees);
        }

        emit Redeemed(idsOut, to);
    }

    // TODO: add NATSPEC
    function swap(
        uint256[] calldata idsIn,
        uint256[] calldata amounts /* ignored for ERC721 vaults */,
        uint256[] calldata idsOut,
        bool forceFees
    ) external payable override returns (uint256 ethFees) {
        return swapTo(idsIn, amounts, idsOut, msg.sender, forceFees);
    }

    // TODO: add NATSPEC
    function swapTo(
        uint256[] calldata idsIn,
        uint256[] calldata amounts /* ignored for ERC721 vaults */,
        uint256[] calldata idsOut,
        address to,
        bool forceFees
    ) public payable override nonReentrant returns (uint256 ethFees) {
        _onlyOwnerIfPaused(3);
        uint256 count;
        if (is1155) {
            for (uint256 i; i < idsIn.length; ++i) {
                uint256 amount = amounts[i];

                if (amount == 0) revert TransferAmountIsZero();
                count += amount;
            }
        } else {
            count = idsIn.length;
        }

        if (count != idsOut.length) revert TokenLengthMismatch();

        (, , uint256 swapFee) = vaultFees();
        uint256 totalVaultFee = (swapFee * idsOut.length);

        // Give the NFTs first, so the user wont get the same thing back, just to be nice.
        (
            uint256 netVTokenPremium,
            uint256[] memory vTokenPremiums,
            address[] memory depositors
        ) = _withdrawNFTsTo(idsOut, to, forceFees);

        ethFees = _chargeAndDistributeFees(
            msg.value,
            true,
            totalVaultFee,
            netVTokenPremium,
            vTokenPremiums,
            depositors,
            forceFees
        );

        _receiveNFTs(idsIn, amounts);

        _refundETH(msg.value, ethFees);

        emit Swapped(idsIn, amounts, idsOut, to);
    }

    // TODO: add NATSPEC
    function flashLoan(
        IERC3156FlashBorrowerUpgradeable receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) public override(ERC20FlashMintUpgradeable, INFTXVaultV3) returns (bool) {
        _onlyOwnerIfPaused(4);
        return super.flashLoan(receiver, token, amount, data);
    }

    // =============================================================
    //                     ONLY PRIVILEGED WRITE
    // =============================================================

    // TODO: add NATSPEC
    function finalizeVault() external override {
        setManager(address(0));
    }

    function setVaultMetadata(
        string calldata name_,
        string calldata symbol_
    ) external override {
        _onlyPrivileged();
        _setMetadata(name_, symbol_);
    }

    function setVaultFeatures(
        bool enableMint_,
        bool enableTargetRedeem_,
        bool enableTargetSwap_
    ) public override {
        _onlyPrivileged();
        enableMint = enableMint_;

        emit EnableMintUpdated(enableMint_);
        emit EnableTargetRedeemUpdated(enableTargetRedeem_);
        emit EnableTargetSwapUpdated(enableTargetSwap_);
    }

    function setFees(
        uint256 mintFee_,
        uint256 redeemFee_,
        uint256 swapFee_
    ) public override {
        _onlyPrivileged();
        vaultFactory.setVaultFees(vaultId, mintFee_, redeemFee_, swapFee_);
    }

    function disableVaultFees() public override {
        _onlyPrivileged();
        vaultFactory.disableVaultFees(vaultId);
    }

    // This function allows for an easy setup of any eligibility module contract from the EligibilityManager.
    // It takes in ABI encoded parameters for the desired module. This is to make sure they can all follow
    // a similar interface.
    function deployEligibilityStorage(
        uint256 moduleIndex,
        bytes calldata initData
    ) external override returns (address) {
        _onlyPrivileged();
        if (address(eligibilityStorage) != address(0))
            revert EligibilityAlreadySet();

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
    // function setEligibilityStorage(address _newEligibility) public {
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
    function setManager(address manager_) public override {
        _onlyPrivileged();
        manager = manager_;
        emit ManagerSet(manager_);
    }

    function rescueTokens(IERC20Upgradeable token) external override {
        _onlyPrivileged();
        uint256 balance = token.balanceOf(address(this));
        token.safeTransfer(msg.sender, balance);
    }

    function rescueERC721(
        IERC721Upgradeable nft,
        uint256[] calldata ids
    ) external override {
        _onlyPrivileged();
        require(address(nft) != assetAddress);

        for (uint256 i; i < ids.length; ++i) {
            nft.safeTransferFrom(address(this), msg.sender, ids[i]);
        }
    }

    function rescueERC1155(
        IERC1155Upgradeable nft,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external override {
        _onlyPrivileged();
        require(address(nft) != assetAddress);

        nft.safeBatchTransferFrom(address(this), msg.sender, ids, amounts, "");
    }

    // =============================================================
    //                     PUBLIC / EXTERNAL VIEW
    // =============================================================

    function vaultFees()
        public
        view
        override
        returns (uint256 mintFee, uint256 redeemFee, uint256 swapFee)
    {
        return vaultFactory.vaultFees(vaultId);
    }

    function allValidNFTs(
        uint256[] memory tokenIds
    ) public view override returns (bool) {
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
    ) external view override returns (uint256) {
        return _holdings.at(holdingsIndex);
    }

    function allHoldings() external view override returns (uint256[] memory) {
        uint256 len = _holdings.length();
        uint256[] memory idArray = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            idArray[i] = _holdings.at(i);
        }
        return idArray;
    }

    function totalHoldings() external view override returns (uint256) {
        return _holdings.length();
    }

    function version() external pure returns (string memory) {
        return "v3.0.0";
    }

    function getVTokenPremium721(
        uint256 tokenId
    ) external view override returns (uint256 premium, address depositor) {
        TokenDepositInfo memory depositInfo = tokenDepositInfo[tokenId];
        depositor = depositInfo.depositor;

        uint256 premiumMax = vaultFactory.premiumMax();
        uint256 premiumDuration = vaultFactory.premiumDuration();

        premium = _getVTokenPremium(
            depositInfo.timestamp,
            premiumMax,
            premiumDuration
        );
    }

    function getVTokenPremium1155(
        uint256 tokenId,
        uint256 amount
    )
        external
        view
        override
        returns (
            uint256 netPremium,
            uint256[] memory premiums,
            address[] memory depositors
        )
    {
        require(amount > 0);

        // max possible array lengths
        premiums = new uint256[](amount);
        depositors = new address[](amount);

        uint256 _pointerIndex1155 = pointerIndex1155[tokenId];

        uint256 i = _pointerIndex1155;
        // cache
        uint256 premiumMax = vaultFactory.premiumMax();
        uint256 premiumDuration = vaultFactory.premiumDuration();
        while (true) {
            DepositInfo1155 memory depositInfo = depositInfo1155[tokenId][i];

            if (depositInfo.qty > amount) {
                uint256 vTokenPremium = _getVTokenPremium(
                    depositInfo.timestamp,
                    premiumMax,
                    premiumDuration
                ) * amount;
                netPremium += vTokenPremium;

                premiums[i] = vTokenPremium;
                depositors[i] = depositInfo.depositor;

                // end loop
                break;
            } else {
                amount -= depositInfo.qty;

                uint256 vTokenPremium = _getVTokenPremium(
                    depositInfo.timestamp,
                    premiumMax,
                    premiumDuration
                ) * depositInfo.qty;
                netPremium += vTokenPremium;

                premiums[i] = vTokenPremium;
                depositors[i] = depositInfo.depositor;

                unchecked {
                    ++i;
                }
            }
        }

        uint256 finalArrayLength = i - _pointerIndex1155 + 1;

        if (finalArrayLength < premiums.length) {
            // change array length
            assembly {
                mstore(premiums, finalArrayLength)
                mstore(depositors, finalArrayLength)
            }
        }
    }

    function vTokenToETH(
        uint256 vTokenAmount
    ) external view override returns (uint256 ethAmount) {
        (ethAmount, ) = _vTokenToETH(vaultFactory, vTokenAmount);
    }

    function depositInfo1155Length(
        uint256 tokenId
    ) external view override returns (uint256) {
        return depositInfo1155[tokenId].length;
    }

    // =============================================================
    //                        INTERNAL HELPERS
    // =============================================================

    // We set a hook to the eligibility module (if it exists) after redeems in case anything needs to be modified.
    function _afterRedeemHook(uint256[] memory tokenIds) internal {
        INFTXEligibility _eligibilityStorage = eligibilityStorage;
        if (address(_eligibilityStorage) == address(0)) {
            return;
        }
        _eligibilityStorage.afterRedeemHook(tokenIds);
    }

    function _receiveNFTs(
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) internal returns (uint256) {
        if (!allValidNFTs(tokenIds)) revert NotEligible();

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
            for (uint256 i; i < tokenIds.length; ++i) {
                uint256 tokenId = tokenIds[i];
                uint256 amount = amounts[i];

                if (amount == 0) revert TransferAmountIsZero();

                if (_quantity1155[tokenId] == 0) {
                    _holdings.add(tokenId);
                }
                _quantity1155[tokenId] += amount;
                count += amount;

                depositInfo1155[tokenId].push(
                    DepositInfo1155({
                        qty: amount,
                        depositor: msg.sender,
                        timestamp: uint48(block.timestamp)
                    })
                );
            }
            return count;
        } else {
            address _assetAddress = assetAddress;
            for (uint256 i; i < tokenIds.length; ++i) {
                uint256 tokenId = tokenIds[i];
                // We may already own the NFT here so we check in order:
                // Does the vault own it?
                //   - If so, check if its in holdings list
                //      - If so, we reject. This means the NFT has already been claimed for.
                //      - If not, it means we have not yet accounted for this NFT, so we continue.
                //   -If not, we "pull" it from the msg.sender and add to holdings.
                _transferFromERC721(_assetAddress, tokenId);
                _holdings.add(tokenId);
                tokenDepositInfo[tokenId] = TokenDepositInfo({
                    timestamp: uint48(block.timestamp),
                    depositor: msg.sender
                });
            }
            return tokenIds.length;
        }
    }

    function _withdrawNFTsTo(
        uint256[] calldata specificIds,
        address to,
        bool forceFees
    )
        internal
        returns (
            uint256 netVTokenPremium,
            uint256[] memory vTokenPremiums,
            address[] memory depositors
        )
    {
        // cache
        bool _is1155 = is1155;
        address _assetAddress = assetAddress;
        INFTXVaultFactoryV3 _vaultFactory = vaultFactory;

        bool deductFees = forceFees ||
            !_vaultFactory.excludedFromFees(msg.sender);

        uint256 premiumMax;
        uint256 premiumDuration;

        if (deductFees) {
            premiumMax = vaultFactory.premiumMax();
            premiumDuration = vaultFactory.premiumDuration();

            vTokenPremiums = new uint256[](specificIds.length);
            depositors = new address[](specificIds.length);
        }

        for (uint256 i; i < specificIds.length; ++i) {
            // This will always be fine considering the validations made above.
            uint256 tokenId = specificIds[i];

            if (_is1155) {
                _quantity1155[tokenId] -= 1;
                if (_quantity1155[tokenId] == 0) {
                    _holdings.remove(tokenId);
                }

                IERC1155Upgradeable(_assetAddress).safeTransferFrom(
                    address(this),
                    to,
                    tokenId,
                    1,
                    ""
                );

                uint256 _pointerIndex1155 = pointerIndex1155[tokenId];
                DepositInfo1155 storage depositInfo = depositInfo1155[tokenId][
                    _pointerIndex1155
                ];
                uint256 _qty = depositInfo.qty;

                depositInfo.qty = _qty - 1;

                // if it was the last nft from this deposit
                if (_qty == 1) {
                    pointerIndex1155[tokenId] = _pointerIndex1155 + 1;
                }

                if (deductFees) {
                    uint256 vTokenPremium = _getVTokenPremium(
                        depositInfo.timestamp,
                        premiumMax,
                        premiumDuration
                    );
                    netVTokenPremium += vTokenPremium;

                    vTokenPremiums[i] = vTokenPremium;
                    depositors[i] = depositInfo.depositor;
                }
            } else {
                if (deductFees) {
                    TokenDepositInfo memory depositInfo = tokenDepositInfo[
                        tokenId
                    ];

                    uint256 vTokenPremium = _getVTokenPremium(
                        depositInfo.timestamp,
                        premiumMax,
                        premiumDuration
                    );
                    netVTokenPremium += vTokenPremium;

                    vTokenPremiums[i] = vTokenPremium;
                    depositors[i] = depositInfo.depositor;
                }

                _holdings.remove(tokenId);
                _transferERC721(_assetAddress, to, tokenId);
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
        INFTXVaultFactoryV3 _vaultFactory = vaultFactory;

        if (_vaultFactory.excludedFromFees(msg.sender)) {
            return 0;
        }

        INFTXFeeDistributorV3 feeDistributor;
        (ethAmount, feeDistributor) = _vTokenToETH(
            _vaultFactory,
            vTokenFeeAmount
        );

        if (ethAmount > 0) {
            if (ethReceived < ethAmount) revert InsufficientETHSent();

            WETH.deposit{value: ethAmount}();
            WETH.transfer(address(feeDistributor), ethAmount);
            feeDistributor.distribute(vaultId);
        }
    }

    function _chargeAndDistributeFees(
        uint256 ethOrWethReceived,
        bool isETH,
        uint256 totalVaultFees,
        uint256 netVTokenPremium,
        uint256[] memory vTokenPremiums,
        address[] memory depositors,
        bool forceFees
    ) internal returns (uint256 ethAmount) {
        // cache
        INFTXVaultFactoryV3 _vaultFactory = vaultFactory;

        if (!forceFees && _vaultFactory.excludedFromFees(msg.sender)) {
            return 0;
        }

        uint256 vaultETHFees;
        INFTXFeeDistributorV3 feeDistributor;
        (vaultETHFees, feeDistributor) = _vTokenToETH(
            _vaultFactory,
            totalVaultFees
        );

        if (vaultETHFees > 0) {
            uint256 netETHPremium;
            uint256 netETHPremiumForDepositors;
            if (netVTokenPremium > 0) {
                netETHPremium =
                    (vaultETHFees * netVTokenPremium) /
                    totalVaultFees;
                netETHPremiumForDepositors =
                    (netETHPremium * vaultFactory.depositorPremiumShare()) /
                    1 ether;
            }
            ethAmount = vaultETHFees + netETHPremium;

            if (ethOrWethReceived < ethAmount) revert InsufficientETHSent();

            if (isETH) {
                WETH.deposit{value: ethAmount}();
            } else {
                // pull only required weth from sender
                WETH.transferFrom(msg.sender, address(this), ethAmount);
            }

            WETH.transfer(
                address(feeDistributor),
                ethAmount - netETHPremiumForDepositors
            );
            feeDistributor.distribute(vaultId);

            for (uint256 i; i < vTokenPremiums.length; ) {
                if (vTokenPremiums[i] > 0) {
                    WETH.transfer(
                        depositors[i],
                        (netETHPremiumForDepositors * vTokenPremiums[i]) /
                            netVTokenPremium
                    );
                }

                unchecked {
                    ++i;
                }
            }
        }
    }

    function _getTwapX96(
        address pool
    ) internal view returns (uint256 priceX96) {
        // secondsAgos[0] (from [before]) -> secondsAgos[1] (to [now])
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = vaultFactory.twapInterval();
        secondsAgos[1] = 0;

        (bool success, bytes memory data) = pool.staticcall(
            abi.encodeWithSelector(
                IUniswapV3PoolDerivedState.observe.selector,
                secondsAgos
            )
        );

        // observe might fail for newly created pools that don't have sufficient observations yet
        if (!success) {
            if (
                keccak256(data) !=
                keccak256(abi.encodeWithSignature("Error(string)", "OLD"))
            ) {
                return 0;
            }

            // observations = [0, 1, 2, ..., index, (index + 1), ..., (cardinality - 1)]
            // Case 1: if entire array initialized once, then oldest observation at (index + 1) % cardinality
            // Case 2: array only initialized till index, then oldest obseravtion at index 0

            // Check Case 1
            (, , uint16 index, uint16 cardinality, , , ) = IUniswapV3Pool(pool)
                .slot0();

            (
                uint32 oldestAvailableTimestamp,
                ,
                ,
                bool initialized
            ) = IUniswapV3Pool(pool).observations((index + 1) % cardinality);

            // Case 2
            if (!initialized)
                (oldestAvailableTimestamp, , , ) = IUniswapV3Pool(pool)
                    .observations(0);

            // get corresponding observation
            secondsAgos[0] = uint32(block.timestamp - oldestAvailableTimestamp);
            (success, data) = pool.staticcall(
                abi.encodeWithSelector(
                    IUniswapV3PoolDerivedState.observe.selector,
                    secondsAgos
                )
            );
            // might revert if oldestAvailableTimestamp == block.timestamp, so we return price as 0
            if (!success) {
                return 0;
            }
        }

        int56[] memory tickCumulatives = abi.decode(data, (int56[])); // don't bother decoding the liquidityCumulatives array

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
        INFTXVaultFactoryV3 _vaultFactory,
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

    function _getVTokenPremium(
        uint48 timestamp,
        uint256 premiumMax,
        uint256 premiumDuration
    ) internal view returns (uint256) {
        return
            ExponentialPremium.getPremium(
                timestamp,
                premiumMax,
                premiumDuration
            );
    }

    /// @dev Must satisfy ethReceived >= ethFees
    function _refundETH(uint256 ethReceived, uint256 ethFees) internal {
        uint256 ethRefund = ethReceived - ethFees;
        if (ethRefund > 0) {
            TransferLib.transferETH(msg.sender, ethRefund);
        }
    }

    function _transferERC721(
        address assetAddr,
        address to,
        uint256 tokenId
    ) internal {
        bytes memory data;

        if (assetAddr != CRYPTO_PUNKS && assetAddr != CRYPTO_KITTIES) {
            // Default
            data = abi.encodeWithSignature(
                "safeTransferFrom(address,address,uint256)",
                address(this),
                to,
                tokenId
            );
        } else if (assetAddr == CRYPTO_PUNKS) {
            data = abi.encodeWithSignature(
                "transferPunk(address,uint256)",
                to,
                tokenId
            );
        } else {
            data = abi.encodeWithSignature(
                "transfer(address,uint256)",
                to,
                tokenId
            );
        }

        (bool success, bytes memory returnData) = address(assetAddr).call(data);
        require(success, string(returnData));
    }

    function _transferFromERC721(address assetAddr, uint256 tokenId) internal {
        bytes memory data;

        if (assetAddr != CRYPTO_PUNKS && assetAddr != CRYPTO_KITTIES) {
            // Default
            // Allow other contracts to "push" into the vault, safely.
            // If we already have the token requested, make sure we don't have it in the list to prevent duplicate minting.
            if (
                IERC721Upgradeable(assetAddress).ownerOf(tokenId) ==
                address(this)
            ) {
                if (_holdings.contains(tokenId)) revert NFTAlreadyOwned();

                return;
            } else {
                data = abi.encodeWithSignature(
                    "safeTransferFrom(address,address,uint256)",
                    msg.sender,
                    address(this),
                    tokenId
                );
            }
        } else if (assetAddr == CRYPTO_PUNKS) {
            // To prevent frontrun attack
            bytes memory punkIndexToAddress = abi.encodeWithSignature(
                "punkIndexToAddress(uint256)",
                tokenId
            );
            (bool checkSuccess, bytes memory result) = address(assetAddr)
                .staticcall(punkIndexToAddress);
            address nftOwner = abi.decode(result, (address));

            if (!checkSuccess || nftOwner != msg.sender) revert NotNFTOwner();

            data = abi.encodeWithSignature("buyPunk(uint256)", tokenId);
        } else {
            data = abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                msg.sender,
                address(this),
                tokenId
            );
        }

        (bool success, bytes memory resultData) = address(assetAddr).call(data);
        require(success, string(resultData));
    }

    function _onlyPrivileged() internal view {
        if (manager == address(0)) {
            if (msg.sender != owner()) revert NotOwner();
        } else {
            if (msg.sender != manager) revert NotManager();
        }
    }

    function _onlyOwnerIfPaused(uint256 lockId) internal view {
        if (vaultFactory.isLocked(lockId) && msg.sender != owner())
            revert Paused();
    }
}