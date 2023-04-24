// SPDX-License-Identifier: MIT
pragma solidity =0.8.15;

import {ERC721Upgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol";

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "@uni-core/libraries/FullMath.sol";
import {FixedPoint128} from "@uni-core/libraries/FixedPoint128.sol";
import {PausableUpgradeable} from "./util/PausableUpgradeable.sol";

import {INFTXVaultFactory} from "@src/v2/interface/INFTXVaultFactory.sol";
import {ITimelockExcludeList} from "@src/v2/interface/ITimelockExcludeList.sol";
import {INFTXFeeDistributorV3} from "./interfaces/INFTXFeeDistributorV3.sol";
import {INFTXInventoryStakingV3} from "./interfaces/INFTXInventoryStakingV3.sol";

/**
 * @title NFTX Inventory Staking V3
 * @author @apoorvlathey
 *
 * @dev lockId's:
 * 0: deposit
 * 1: withdraw
 * 2: collectWethFees
 * 3: receiveRewards
 *
 * @notice Allows users to stake vTokens to earn fees in vTokens and WETH. The position is minted as xNFT.
 */

contract NFTXInventoryStakingV3Upgradeable is
    INFTXInventoryStakingV3,
    ERC721Upgradeable,
    PausableUpgradeable
{
    // details about the staking position
    struct Position {
        // the nonce for permits
        uint256 nonce; // TODO: add permit logic
        // vaultId corresponding to the vTokens staked in this position
        uint256 vaultId;
        // timestamp at which the timelock expires
        uint256 timelockedUntil;
        // shares balance is used to track position's ownership of total vToken balance
        uint256 vTokenShareBalance;
        // used to evaluate weth fees accumulated per vTokenShare since this snapshot
        uint256 wethFeesPerVTokenShareSnapshotX128;
        // owed weth fees, updates when positions merged
        uint256 wethOwed;
    }

    struct VaultGlobal {
        uint256 netVTokenBalance; // vToken liquidity + earned fees
        uint256 totalVTokenShares;
        uint256 globalWethFeesPerVTokenShareX128;
    }

    INFTXVaultFactory public override nftxVaultFactory;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 private _nextId = 1;

    /// @dev timelock in seconds
    uint256 public timelock;
    /// @dev the max penalty applicable. The penalty goes down linearly as the `timelockedUntil` approaches
    uint256 public earlyWithdrawPenaltyInWei;

    ITimelockExcludeList public timelockExcludeList;

    IERC20 public WETH;

    /// @dev The token ID position data
    mapping(uint256 => Position) public positions;

    /// @dev vaultId => VaultGlobal
    mapping(uint256 => VaultGlobal) public vaultGlobal;

    // =============================================================
    //                           INIT
    // =============================================================

    function __NFTXInventoryStaking_init(
        INFTXVaultFactory nftxVaultFactory_,
        uint256 timelock_,
        uint256 earlyWithdrawPenaltyInWei_,
        ITimelockExcludeList timelockExcludeList_
    ) external initializer {
        // TODO: finalize token name and symbol
        __ERC721_init("NFTX Inventory Staking", "xNFT");
        __Pausable_init();

        nftxVaultFactory = nftxVaultFactory_;
        WETH = INFTXFeeDistributorV3(nftxVaultFactory_.feeDistributor()).WETH();

        if (timelock_ > 14 days) revert TimelockTooLong();
        timelock = timelock_;
        earlyWithdrawPenaltyInWei = earlyWithdrawPenaltyInWei_;
        timelockExcludeList = timelockExcludeList_;
    }

    // =============================================================
    //                     PUBLIC / EXTERNAL WRITE
    // =============================================================

    function deposit(
        uint256 vaultId,
        uint256 amount,
        address recipient
    ) external returns (uint256 tokenId) {
        onlyOwnerIfPaused(0);

        address vToken = nftxVaultFactory.vault(vaultId);
        VaultGlobal storage _vaultGlobal = vaultGlobal[vaultId];

        uint256 preVTokenBalance = _vaultGlobal.netVTokenBalance;
        IERC20(vToken).transferFrom(msg.sender, address(this), amount);
        _vaultGlobal.netVTokenBalance = preVTokenBalance + amount;

        _mint(recipient, (tokenId = _nextId++));

        uint256 vTokenShares;
        if (_vaultGlobal.totalVTokenShares == 0) {
            vTokenShares = amount;
        } else {
            vTokenShares =
                (amount * _vaultGlobal.totalVTokenShares) /
                preVTokenBalance;
        }
        _vaultGlobal.totalVTokenShares += vTokenShares;

        positions[tokenId] = Position({
            nonce: 0,
            vaultId: vaultId,
            timelockedUntil: timelockExcludeList.isExcluded(msg.sender, vaultId)
                ? 0
                : block.timestamp + timelock,
            vTokenShareBalance: vTokenShares,
            wethFeesPerVTokenShareSnapshotX128: _vaultGlobal
                .globalWethFeesPerVTokenShareX128,
            wethOwed: 0
        });

        emit Deposit(vaultId, tokenId, amount);
    }

    function withdraw(uint256 positionId, uint256 vTokenShares) external {
        onlyOwnerIfPaused(1);

        if (ownerOf(positionId) != msg.sender) revert NotPositionOwner();

        Position storage position = positions[positionId];

        uint256 positionvTokenShareBalance = position.vTokenShareBalance;
        require(positionvTokenShareBalance >= vTokenShares);

        uint256 vaultId = position.vaultId;
        VaultGlobal storage _vaultGlobal = vaultGlobal[vaultId];
        // withdraw vTokens corresponding to the vTokenShares requested
        uint256 vTokenOwed = (_vaultGlobal.netVTokenBalance * vTokenShares) /
            _vaultGlobal.totalVTokenShares;
        // withdraw all the weth fees accrued
        uint256 wethOwed = FullMath.mulDiv(
            _vaultGlobal.globalWethFeesPerVTokenShareX128 -
                position.wethFeesPerVTokenShareSnapshotX128,
            positionvTokenShareBalance,
            FixedPoint128.Q128
        );
        position.wethFeesPerVTokenShareSnapshotX128 = _vaultGlobal
            .globalWethFeesPerVTokenShareX128;

        if (block.timestamp <= position.timelockedUntil) {
            // Eg: timelock = 10 days, vTokenOwed = 100, penalty% = 5%
            // Case 1: Instant withdraw, with 10 days left
            // penaltyAmt = 100 * 5% = 5
            // Case 2: With 2 days timelock left
            // penaltyAmt = (100 * 5%) * 2 / 10 = 1
            uint256 vTokenPenalty = ((position.timelockedUntil -
                block.timestamp) *
                vTokenOwed *
                earlyWithdrawPenaltyInWei) / (timelock * 1 ether);
            vTokenOwed -= vTokenPenalty;
        }

        // in case of penalty, more shares are burned than the corresponding vToken balance
        // resulting in an increase of `pricePerShareVToken`, hence the penalty collected is distributed amongst other stakers
        _vaultGlobal.netVTokenBalance -= vTokenOwed;
        _vaultGlobal.totalVTokenShares -= vTokenShares;

        // transfer tokens to the user
        IERC20(nftxVaultFactory.vault(vaultId)).transfer(
            msg.sender,
            vTokenOwed
        );
        WETH.transfer(msg.sender, wethOwed + position.wethOwed);

        emit Withdraw(positionId, vTokenShares, vTokenOwed, wethOwed);
    }

    // combine multiple xNFTs (if timelock expired)
    function combinePositions(
        uint256 parentPositionId,
        uint256[] calldata childrenPositionIds
    ) external {
        if (ownerOf(parentPositionId) != msg.sender) revert NotPositionOwner();
        Position storage parentPosition = positions[parentPositionId];
        uint256 parentVaultId = parentPosition.vaultId;

        VaultGlobal storage _vaultGlobal = vaultGlobal[parentVaultId];

        if (block.timestamp <= parentPosition.timelockedUntil)
            revert Timelocked();

        uint256 netWethOwed;
        uint256 childrenPositionsCount = childrenPositionIds.length;
        for (uint256 i; i < childrenPositionsCount; ) {
            if (ownerOf(childrenPositionIds[i]) != msg.sender)
                revert NotPositionOwner();

            Position storage childPosition = positions[childrenPositionIds[i]];
            if (block.timestamp <= childPosition.timelockedUntil)
                revert Timelocked();
            if (childPosition.vaultId != parentVaultId)
                revert VaultIdMismatch();

            // add weth owed for this child position
            netWethOwed += FullMath.mulDiv(
                _vaultGlobal.globalWethFeesPerVTokenShareX128 -
                    childPosition.wethFeesPerVTokenShareSnapshotX128,
                childPosition.vTokenShareBalance,
                FixedPoint128.Q128
            );
            netWethOwed += childPosition.wethOwed;
            // transfer vToken share balance to parent position
            parentPosition.vTokenShareBalance += childPosition
                .vTokenShareBalance;
            childPosition.vTokenShareBalance = 0;
            childPosition.wethOwed = 0;

            unchecked {
                ++i;
            }
        }

        // add weth owed for the parent position
        netWethOwed += FullMath.mulDiv(
            _vaultGlobal.globalWethFeesPerVTokenShareX128 -
                parentPosition.wethFeesPerVTokenShareSnapshotX128,
            parentPosition.vTokenShareBalance,
            FixedPoint128.Q128
        );
        // set new wethFeesPerVTokenShare snapshot
        parentPosition.wethFeesPerVTokenShareSnapshotX128 = _vaultGlobal
            .globalWethFeesPerVTokenShareX128;

        // add net wethOwed to the parent position
        parentPosition.wethOwed += netWethOwed;
    }

    function collectWethFees(uint256 positionId) external {
        onlyOwnerIfPaused(2);

        if (ownerOf(positionId) != msg.sender) revert NotPositionOwner();

        Position storage position = positions[positionId];
        uint256 positionvTokenShareBalance = position.vTokenShareBalance;
        VaultGlobal storage _vaultGlobal = vaultGlobal[position.vaultId];
        uint256 wethOwed = FullMath.mulDiv(
            _vaultGlobal.globalWethFeesPerVTokenShareX128 -
                position.wethFeesPerVTokenShareSnapshotX128,
            positionvTokenShareBalance,
            FixedPoint128.Q128
        );
        position.wethFeesPerVTokenShareSnapshotX128 = _vaultGlobal
            .globalWethFeesPerVTokenShareX128;

        WETH.transfer(msg.sender, wethOwed + position.wethOwed);

        emit CollectWethFees(positionId, wethOwed);
    }

    /// @dev Can only be called by feeDistributor, after it sends the reward tokens to this contract
    function receiveRewards(
        uint256 vaultId,
        uint256 amount,
        bool isRewardWeth
    ) external returns (bool rewardsDistributed) {
        onlyOwnerIfPaused(3);
        require(msg.sender == nftxVaultFactory.feeDistributor());

        VaultGlobal storage _vaultGlobal = vaultGlobal[vaultId];
        if (_vaultGlobal.totalVTokenShares == 0) {
            return false;
        }
        rewardsDistributed = true;
        WETH.transferFrom(msg.sender, address(this), amount);

        if (isRewardWeth) {
            _vaultGlobal.globalWethFeesPerVTokenShareX128 += FullMath.mulDiv(
                amount,
                FixedPoint128.Q128,
                _vaultGlobal.totalVTokenShares
            );
        } else {
            _vaultGlobal.netVTokenBalance += amount;
        }
    }

    // =============================================================
    //                        ONLY OWNER WRITE
    // =============================================================

    function setTimelock(uint256 timelock_) external onlyOwner {
        if (timelock_ > 14 days) revert TimelockTooLong();

        timelock = timelock_;
    }

    function setEarlyWithdrawPenalty(
        uint256 earlyWithdrawPenaltyInWei_
    ) external onlyOwner {
        earlyWithdrawPenaltyInWei = earlyWithdrawPenaltyInWei_;
    }

    // =============================================================
    //                     PUBLIC / EXTERNAL VIEW
    // =============================================================

    function pricePerShareVToken(
        uint256 vaultId
    ) external view returns (uint256) {
        VaultGlobal storage _vaultGlobal = vaultGlobal[vaultId];
        return
            (_vaultGlobal.netVTokenBalance * 1 ether) /
            _vaultGlobal.totalVTokenShares;
    }
}
