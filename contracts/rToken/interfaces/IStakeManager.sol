pragma solidity >=0.7.0 <0.9.0;

interface IStakeManager {
    function addPool(address pool) public;
    function getPools() public view returns (address[] memory);
    function isPool(address pool) public view returns (bool);

    function bond(address pool, adderss group, address lesser, address greater) external payable;
    function unbond(address pool, address group, uint256 value, address lesser, address greater, uint256 index);
    function withdraw(address, uint256) external;

    function activate(address pool, address group) external;
}