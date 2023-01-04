pragma solidity 0.7.6;

interface ISlashIndicator {
  function clean() external;
  function sendFelonyPackage(address validator) external;
  function getSlashThresholds() external view returns (uint256, uint256);
}
