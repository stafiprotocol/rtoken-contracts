pragma solidity 0.7.6;

interface IRelayerIncentivize {

    function addReward(address payable headerRelayerAddr, address payable packageRelayer, uint256 amount, bool fromSystemReward) external returns (bool);

}
