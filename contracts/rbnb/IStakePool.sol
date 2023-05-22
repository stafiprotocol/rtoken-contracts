pragma solidity 0.7.6;

// SPDX-License-Identifier: GPL-3.0-only

interface IStakePool {
    function checkAndClaimReward() external returns (uint256);

    function checkAndClaimUndelegated() external returns (uint256);

    function delegate(address validator, uint256 amount) external;

    function undelegate(address validator, uint256 amount) external;

    function delegateVals(address[] calldata validatorList, uint256[] calldata amountList) external;

    function undelegateVals(address[] calldata validatorList, uint256[] calldata amountList) external;

    function redelegate(address validatorSrc, address validatorDst, uint256 amount) external;

    function withdrawForStaker(address staker, uint256 amount) external;

    function getTotalDelegated() external view returns (uint256);

    function getDelegated(address validator) external view returns (uint256);

    function getMinDelegation() external view returns (uint256);

    function getPendingUndelegateTime(address validator) external view returns (uint256);

    function getPendingRedelegateTime(address valSrc, address valDst) external view returns (uint256);

    function getRequestInFly() external view returns (uint256[3] memory);

    function getRelayerFee() external view returns (uint256);
}
