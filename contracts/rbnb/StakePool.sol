pragma solidity 0.7.6;
import "./IStaking.sol";

// SPDX-License-Identifier: GPL-3.0-only
contract StakePool {
    address public stakingAddress;
    address public stakeManager;

    modifier onlyStakeManager() {
        require(msg.sender == stakeManager, "only stakeManager");
        _;
    }

    function checkAndClaimReward() external onlyStakeManager returns (uint256) {
        if (IStaking(stakingAddress).getDistributedReward(address(this)) > 0) {
            return IStaking(stakingAddress).claimReward();
        }
        return 0;
    }

    function checkAndClaimUndelegated() external onlyStakeManager returns (uint256) {
        if (IStaking(stakingAddress).getUndelegated(address(this)) > 0) {
            return IStaking(stakingAddress).claimUndelegated();
        }
        return 0;
    }
}
