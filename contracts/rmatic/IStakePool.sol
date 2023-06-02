pragma solidity 0.7.6;

// SPDX-License-Identifier: GPL-3.0-only

interface IStakePool {
    function checkAndWithdrawRewards(address[] calldata validator) external returns (uint256 reward);

    function buyVoucher(address validator, uint256 _amount) external returns (uint256 amountToDeposit);

    function sellVoucher_new(address validator, uint256 claimAmount) external;

    function unstakeClaimTokens_new(address validator, uint256 unbondNonce) external;

    function withdrawForStaker(address _erc20TokenAddress, address staker, uint256 amount) external;

    function getTotalStakeOnValidator(address validator) external view returns (uint256);

    function getTotalStakeOnValidators(address[] calldata validator) external view returns (uint256);

    function getLiquidRewards(address validator) external view returns (uint256);
}
