pragma solidity 0.7.6;

// SPDX-License-Identifier: GPL-3.0-only

interface IGovStakeManager {
    function migrateDelegation(uint256 fromValidatorId, uint256 toValidatorId, uint256 amount) external;

    function epoch() external view returns (uint256);

    function withdrawalDelay() external view returns (uint256);

    function getValidatorContract(uint256 validatorId) external view returns (address);
}
