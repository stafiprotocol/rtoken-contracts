pragma solidity 0.7.6;
import "./IStaking.sol";
import "./IStakePool.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";

// SPDX-License-Identifier: GPL-3.0-only
contract StakePool is IStakePool {
    using SafeMath for uint256;

    bytes32 private constant stakingAddressSlot = bytes32(uint256(keccak256("StakePool.proxy.stakingAddressSlot")) - 1);
    bytes32 private constant stakeManagerAddressSlot =
        bytes32(uint256(keccak256("StakePool.proxy.stakeManagerAddressSlot")) - 1);

    modifier onlyStakeManager() {
        require(msg.sender == stakeManagerAddress(), "only stakeManager");
        _;
    }

    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    function init(address _stakingAddress, address _stakeMangerAddress) external {
        require(stakingAddress() == address(0), "already init");
        setStakingAddress(_stakingAddress);
        setStakeManagerAddress(_stakeMangerAddress);
    }

    function stakingAddress() public view returns (address impl) {
        bytes32 slot = stakingAddressSlot;
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

    function setStakingAddress(address _stakingAddress) private {
        bytes32 slot = stakingAddressSlot;
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

    function checkAndClaimReward() external override onlyStakeManager returns (uint256) {
        if (IStaking(stakingAddress()).getDistributedReward(address(this)) > 0) {
            return IStaking(stakingAddress()).claimReward();
        }
        return 0;
    }

    function checkAndClaimUndelegated() external override onlyStakeManager returns (uint256) {
        if (IStaking(stakingAddress()).getUndelegated(address(this)) > 0) {
            return IStaking(stakingAddress()).claimUndelegated();
        }
        return 0;
    }

    function delegate(
        address[] calldata validatorList,
        uint256[] calldata amountList
    ) external override onlyStakeManager {
        uint256 relayerFee = IStaking(stakingAddress()).getRelayerFee();
        for (uint256 i = 0; i < validatorList.length; ++i) {
            IStaking(stakingAddress()).delegate{value: amountList[i].add(relayerFee)}(validatorList[i], amountList[i]);
        }
    }

    function undelegate(
        address[] calldata validatorList,
        uint256[] calldata amountList
    ) external override onlyStakeManager {
        uint256 relayerFee = IStaking(stakingAddress()).getRelayerFee();
        for (uint256 i = 0; i < validatorList.length; ++i) {
            IStaking(stakingAddress()).undelegate{value: relayerFee}(validatorList[i], amountList[i]);
        }
    }

    function redelegate(address validatorSrc, address validatorDst, uint256 amount) external override onlyStakeManager {
        uint256 relayerFee = IStaking(stakingAddress()).getRelayerFee();
        IStaking(stakingAddress()).redelegate{value: relayerFee}(validatorSrc, validatorDst, amount);
    }

    function claimForStaker(address staker, uint256 amount) external override onlyStakeManager {
        if (amount > 0) {
            (bool result, ) = staker.call{value: amount}("");
            require(result, "call failed");
        }
    }

    function getTotalDelegated() external view override returns (uint256) {
        return IStaking(stakingAddress()).getTotalDelegated(address(this));
    }

    function getDelegated(address validator) external view override returns (uint256) {
        return IStaking(stakingAddress()).getDelegated(address(this), validator);
    }

    function getMinDelegation() external view override returns (uint256) {
        return IStaking(stakingAddress()).getMinDelegation();
    }
}
