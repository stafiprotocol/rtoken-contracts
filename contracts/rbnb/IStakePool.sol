pragma solidity 0.7.6;

// SPDX-License-Identifier: GPL-3.0-only

interface IStakePool {
    function checkAndClaimReward() external returns (uint256);

    function checkAndClaimUndelegated() external returns (uint256);

    function delegate(address[] calldata validatorList, uint256[] calldata amountList) external payable;

    function undelegate(address[] calldata validatorList, uint256[] calldata amountList) external payable;

    function getTotalDelegated() external view returns (uint256);
}
