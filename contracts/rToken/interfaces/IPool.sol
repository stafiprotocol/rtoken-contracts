pragma solidity >=0.7.0 <0.9.0;

interface IPool {
    function bond() external payable;
    function vote(address, uint256, address, address) external returns (bool);
    function activate(address group) external returns (bool);
    function unvote(address, uint256, address, address, uint256) external returns (bool);
    function unbond(uint256) external;
    function withdraw() external returns (uint256[] memory, uint256[] memory);
    function getTotalBonded() public view returns (uint256);
}