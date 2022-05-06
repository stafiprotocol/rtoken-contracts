pragma solidity >=0.7.0 <0.9.0;

interface ILockedGold {
    function getAccountTotalLockedGold(address) external view returns (uint256);
    function getTotalLockedGold() external view returns (uint256);
    function getPendingWithdrawals(address) external view returns (uint256[] memory, uint256[] memory);
    function getTotalPendingWithdrawals(address) external view returns (uint256);
    function lock() external payable;
    function unlock(uint256) external;
    function withdraw(uint256) external;
}