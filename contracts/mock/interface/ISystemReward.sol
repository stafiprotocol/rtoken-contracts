pragma solidity 0.7.6;
// SPDX-License-Identifier: GPL-3.0-only
interface ISystemReward {
  function claimRewards(address payable to, uint256 amount) external returns(uint256 actualAmount);
}