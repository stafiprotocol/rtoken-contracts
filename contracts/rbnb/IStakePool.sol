pragma solidity 0.7.6;

// SPDX-License-Identifier: GPL-3.0-only

interface IStakePool {
    function checkAndClaimReward() external returns (uint256);

    function checkAndClaimUndelegated() external returns (uint256);

    function delegate(address[] calldata validatorList, uint256[] calldata amountList) external;

    function undelegate(address[] calldata validatorList, uint256[] calldata amountList) external;

    function redelegate(address validatorSrc, address validatorDst, uint256 amount) external;

    function claimForStaker(address staker, uint256 amount) external;

    function getTotalDelegated() external view returns (uint256);

    function getDelegated(address validator) external view returns (uint256);
}
