pragma solidity 0.7.6;

// SPDX-License-Identifier: GPL-3.0-only

interface IStakePool {
    function checkAndWithdrawRewards(uint256[] calldata validator) external returns (uint256 reward);

    function delegate(uint256 validator, uint256 amount) external returns (uint256 amountToDeposit);

    function undelegate(uint256 validator, uint256 claimAmount) external;

    function redelegate(uint256 fromValidatorId, uint256 toValidatorId, uint256 amount) external;

    function unstakeClaimTokens(uint256 validator, uint256 claimedNonce) external returns (bool);

    function withdrawForStaker(address erc20TokenAddress, address staker, uint256 amount) external;

    function approveForStakeManager(address erc20TokenAddress, uint256 amount) external;

    function getTotalStakeOnValidator(uint256 validator) external view returns (uint256);

    function getTotalStakeOnValidators(uint256[] calldata validator) external view returns (uint256);

    function getLiquidRewards(uint256 validator) external view returns (uint256);

    function unbondNonces(uint256 validator) external view returns (uint256);
}
