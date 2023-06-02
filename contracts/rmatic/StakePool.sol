pragma solidity 0.7.6;
import "./IValidatorShare.sol";
import "./IStakePool.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";

// SPDX-License-Identifier: GPL-3.0-only
contract StakePool is IStakePool {
    using SafeMath for uint256;

    bytes32 private constant validatorAddressSlot =
        bytes32(uint256(keccak256("StakePool.proxy.validatorAddressSlot")) - 1);
    bytes32 private constant stakeManagerAddressSlot =
        bytes32(uint256(keccak256("StakePool.proxy.stakeManagerAddressSlot")) - 1);

    modifier onlyStakeManager() {
        require(msg.sender == stakeManagerAddress(), "only stakeManager");
        _;
    }

    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    function init(address _stakingAddress, address _stakeMangerAddress) external {
        require(validatorAddress() == address(0), "already init");
        setValidatorAddress(_stakingAddress);
        setStakeManagerAddress(_stakeMangerAddress);
    }

    function validatorAddress() public view returns (address impl) {
        bytes32 slot = validatorAddressSlot;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            impl := sload(slot)
        }
    }

    function stakeManagerAddress() public view returns (address impl) {
        bytes32 slot = stakeManagerAddressSlot;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            impl := sload(slot)
        }
    }

    function setValidatorAddress(address _stakingAddress) private {
        bytes32 slot = validatorAddressSlot;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            sstore(slot, _stakingAddress)
        }
    }

    function setStakeManagerAddress(address _stakeManagerAddress) private {
        bytes32 slot = stakeManagerAddressSlot;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            sstore(slot, _stakeManagerAddress)
        }
    }

    function withdrawRewards() external override {}

    function buyVoucher(
        uint256 _amount,
        uint256 _minSharesToMint
    ) external override returns (uint256 amountToDeposit) {}

    function sellVoucher_new(uint256 claimAmount, uint256 maximumSharesToBurn) external override {}

    function unstakeClaimTokens_new(uint256 unbondNonce) external override {}

    function restake() external override returns (uint256, uint256) {}

    function withdrawForStaker(address staker, uint256 amount) external override onlyStakeManager {
        if (amount > 0) {
            (bool result, ) = staker.call{value: amount}("");
            require(result, "call failed");
        }
    }

    function getTotalStake() external view override returns (uint256) {
        (uint256 totalStake, ) = IValidatorShare(validatorAddress()).getTotalStake(address(this));
        return totalStake;
    }
}
