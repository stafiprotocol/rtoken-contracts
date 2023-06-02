pragma solidity 0.7.6;
import "./IValidatorShare.sol";
import "./IStakePool.sol";
import {SafeERC20, IERC20, SafeMath} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

// SPDX-License-Identifier: GPL-3.0-only
contract StakePool is IStakePool {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    bytes32 private constant stakeManagerAddressSlot =
        bytes32(uint256(keccak256("StakePool.proxy.stakeManagerAddressSlot")) - 1);

    modifier onlyStakeManager() {
        require(msg.sender == stakeManagerAddress(), "only stakeManager");
        _;
    }

    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    function init(address _stakeMangerAddress) external {
        require(stakeManagerAddress() == address(0), "already init");
        setStakeManagerAddress(_stakeMangerAddress);
    }

    function stakeManagerAddress() public view returns (address impl) {
        bytes32 slot = stakeManagerAddressSlot;
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

    function checkAndWithdrawRewards(
        address[] calldata _validators
    ) external override onlyStakeManager returns (uint256) {
        uint256 poolNewReward;
        for (uint256 j = 0; j < _validators.length; ++j) {
            uint256 reward = IValidatorShare(_validators[j]).getLiquidRewards(_validators[j]);
            if (reward > 0) {
                IValidatorShare(_validators[j]).buyVoucher(0, 0);
                poolNewReward = poolNewReward.add(reward);
            }
        }
        return poolNewReward;
    }

    function buyVoucher(
        address _validator,
        uint256 _amount
    ) external override onlyStakeManager returns (uint256 amountToDeposit) {
        return IValidatorShare(_validator).buyVoucher(_amount, 0);
    }

    function sellVoucher_new(address _validator, uint256 _claimAmount) external override onlyStakeManager {
        IValidatorShare(_validator).sellVoucher_new(_claimAmount, _claimAmount);
    }

    function unstakeClaimTokens_new(address _validator, uint256 _unbondNonce) external override onlyStakeManager {
        IValidatorShare(_validator).unstakeClaimTokens_new(_unbondNonce);
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

    function getTotalStakeOnValidator(address _validator) external view override returns (uint256) {
        (uint256 totalStake, ) = IValidatorShare(_validator).getTotalStake(address(this));
        return totalStake;
    }

    function getTotalStakeOnValidators(address[] calldata _validators) external view override returns (uint256) {
        uint256 totalStake;
        for (uint256 j = 0; j < _validators.length; ++j) {
            (uint256 stake, ) = IValidatorShare(_validators[j]).getTotalStake(address(this));
            totalStake = totalStake.add(stake);
        }
        return totalStake;
    }

    function getLiquidRewards(address _validator) external view override returns (uint256) {}
}
