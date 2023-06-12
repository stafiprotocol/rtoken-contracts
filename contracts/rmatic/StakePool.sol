pragma solidity 0.7.6;
pragma abicoder v2;

import "./IValidatorShare.sol";
import "./IGovStakeManager.sol";
import "./IStakePool.sol";
import {SafeERC20, IERC20, SafeMath} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

// SPDX-License-Identifier: GPL-3.0-only
contract StakePool is IStakePool {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    bytes32 private constant stakeManagerAddressSlot =
        bytes32(uint256(keccak256("StakePool.proxy.stakeManagerAddressSlot")) - 1);

    bytes32 private constant govStakeManagerAddressSlot =
        bytes32(uint256(keccak256("StakePool.proxy.govStakeManagerAddressSlot")) - 1);

    modifier onlyStakeManager() {
        require(msg.sender == stakeManagerAddress(), "only stakeManager");
        _;
    }

    function init(address _stakeMangerAddress, address _govStakeMangerAddress) external {
        require(stakeManagerAddress() == address(0), "already init");
        setStakeManagerAddress(_stakeMangerAddress);
        setGovStakeManagerAddress(_govStakeMangerAddress);
    }

    function stakeManagerAddress() public view returns (address impl) {
        bytes32 slot = stakeManagerAddressSlot;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            impl := sload(slot)
        }
    }

    function govStakeManagerAddress() public view returns (address impl) {
        bytes32 slot = govStakeManagerAddressSlot;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            impl := sload(slot)
        }
    }

    function setStakeManagerAddress(address _stakeManagerAddress) private {
        bytes32 slot = stakeManagerAddressSlot;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            sstore(slot, _stakeManagerAddress)
        }
    }

    function setGovStakeManagerAddress(address _govStakeManagerAddress) private {
        bytes32 slot = govStakeManagerAddressSlot;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            sstore(slot, _govStakeManagerAddress)
        }
    }

    function checkAndWithdrawRewards(
        uint256[] calldata _validators
    ) external override onlyStakeManager returns (uint256) {
        uint256 poolNewReward;
        IGovStakeManager govStakeManager = IGovStakeManager(govStakeManagerAddress());
        for (uint256 j = 0; j < _validators.length; ++j) {
            address valAddress = govStakeManager.getValidatorContract(_validators[j]);
            uint256 reward = IValidatorShare(valAddress).getLiquidRewards(address(this));
            if (reward > 0) {
                IValidatorShare(valAddress).buyVoucher(0, 0);
                poolNewReward = poolNewReward.add(reward);
            }
        }
        return poolNewReward;
    }

    function delegate(
        uint256 _validator,
        uint256 _amount
    ) external override onlyStakeManager returns (uint256 amountToDeposit) {
        address valAddress = IGovStakeManager(govStakeManagerAddress()).getValidatorContract(_validator);
        return IValidatorShare(valAddress).buyVoucher(_amount, 0);
    }

    function undelegate(uint256 _validator, uint256 _claimAmount) external override onlyStakeManager {
        address valAddress = IGovStakeManager(govStakeManagerAddress()).getValidatorContract(_validator);
        IValidatorShare(valAddress).sellVoucher_new(_claimAmount, _claimAmount);
    }

    function unstakeClaimTokens(
        uint256 _validator,
        uint256 _claimedNonce
    ) external override onlyStakeManager returns (uint256) {
        IGovStakeManager govStakeManager = IGovStakeManager(govStakeManagerAddress());
        address valAddress = govStakeManager.getValidatorContract(_validator);
        uint256 willClaimedNonce = _claimedNonce.add(1);
        IValidatorShare.DelegatorUnbond memory unbond = IValidatorShare(valAddress).unbonds_new(
            address(this),
            willClaimedNonce
        );

        if (unbond.withdrawEpoch == 0) {
            return _claimedNonce;
        }
        if (unbond.shares == 0) {
            return willClaimedNonce;
        }

        uint256 withdrawDelay = govStakeManager.withdrawalDelay();
        uint256 epoch = govStakeManager.epoch();
        if (unbond.withdrawEpoch.add(withdrawDelay) > epoch) {
            return _claimedNonce;
        }

        IValidatorShare(valAddress).unstakeClaimTokens_new(willClaimedNonce);

        return willClaimedNonce;
    }

    function withdrawForStaker(
        address _erc20TokenAddress,
        address _staker,
        uint256 _amount
    ) external override onlyStakeManager {
        if (_amount > 0) {
            IERC20(_erc20TokenAddress).safeTransfer(_staker, _amount);
        }
    }

    function redelegate(
        uint256 _fromValidatorId,
        uint256 _toValidatorId,
        uint256 _amount
    ) external override onlyStakeManager {
        IGovStakeManager(govStakeManagerAddress()).migrateDelegation(_fromValidatorId, _toValidatorId, _amount);
    }

    function approveForStakeManager(address _erc20TokenAddress, uint256 amount) external override onlyStakeManager {
        IERC20(_erc20TokenAddress).safeIncreaseAllowance(govStakeManagerAddress(), amount);
    }

    function getTotalStakeOnValidator(uint256 _validator) external view override returns (uint256) {
        address valAddress = IGovStakeManager(govStakeManagerAddress()).getValidatorContract(_validator);
        (uint256 totalStake, ) = IValidatorShare(valAddress).getTotalStake(address(this));
        return totalStake;
    }

    function getTotalStakeOnValidators(uint256[] calldata _validators) external view override returns (uint256) {
        uint256 totalStake;
        IGovStakeManager govStakeManager = IGovStakeManager(govStakeManagerAddress());
        for (uint256 j = 0; j < _validators.length; ++j) {
            address valAddress = govStakeManager.getValidatorContract(_validators[j]);
            (uint256 stake, ) = IValidatorShare(valAddress).getTotalStake(address(this));
            totalStake = totalStake.add(stake);
        }
        return totalStake;
    }
}
