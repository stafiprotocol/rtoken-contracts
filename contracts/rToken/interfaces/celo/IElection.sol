pragma solidity ^0.5.13;

interface IElection {


    function vote(address, uint256, address, address) external returns (bool);
    function activate(address) external returns (bool);
    function revokeActive(address, uint256, address, address, uint256) external returns (bool);
    function revokeAllActive(address, address, address, uint256) external returns (bool);
    function revokePending(address, uint256, address, address, uint256) external returns (bool);








    function getTotalVotes() external view returns (uint256);
    function getActiveVotes() external view returns (uint256);
    function getTotalVotesByAccount(address) external view returns (uint256);
    function getPendingVotesForGroupByAccount(address, address) external view returns (uint256);
    function getActiveVotesForGroupByAccount(address, address) external view returns (uint256);
    function getTotalVotesForGroupByAccount(address, address) external view returns (uint256);
    function getActiveVoteUnitsForGroupByAccount(address, address) external view returns (uint256);
    function getTotalVotesForGroup(address) external view returns (uint256);
    function getActiveVotesForGroup(address) external view returns (uint256);
    function getPendingVotesForGroup(address) external view returns (uint256);
    function getGroupEligibility(address) external view returns (bool);
    function getGroupEpochRewards(address, uint256, uint256[] calldata)
    external
    view
    returns (uint256);
    function getGroupsVotedForByAccount(address) external view returns (address[] memory);
    function getEligibleValidatorGroups() external view returns (address[] memory);
}