pragma solidity >=0.7.0 <0.9.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "../interfaces/celo/IElection.sol";
import "../interfaces/celo/ILockedGold.sol";
import "../interfaces/IPool.sol";

contract Pool is IPool {
    using SafeMath for uint256;

    // stake manager contract
    address public stakeManager;
    // staking contract, for celo, it is LockedGold.sol.
    address public stakeContract;
    ILockedGold private staking;
    // election contract, for celo, it is Election.sol
    address public electionContract;
    IElection private election;


    constructor(
        address _stakeManager,
        address _stakeContract,
        address _electionContract
    ) {
        stakeManager = _stakeManager;
        stakeContract = _stakeContract;
        staking = ILockedGold(stakeContract);
        electionContract = _electionContract;
        election =  IElection(electionContract);
    }

    modifier onlyStakeManager {
        require(msg.sender == stakeManagerAddress, "Caller must be the stakeManager");
        _;
    }

    function bond() external payable onlyStakeManager {
        staking.lock{value: msg.value}();
    }

    function vote(address group, uint256 value, address lesser, address greater) external onlyStakeManager returns (bool) {
        return election.vote(group, msg.value, lesser, greater);
    }

    function activate(address group) external returns (bool) {
        return election.activate(group);
    }

    function getTotalBonded() public view returns (uint256) {
        return staking.getAccountTotalLockedGold(address(this));
    }

    function unbond(address group, uint256 value, address lesser, address greater, uint256 index) external onlyStakeManager returns (uint256) {
        uint256 pendingVotes = election.getPendingVotesForGroupByAccount(group, address(this));
        if (pendingVotes == 0) {
            bool unvoted = election.revokeActive(group, value, lesser, greater, index);
            require(unvoted, "Revoke active failed");
        } else if (pendingVotes < value) {
            bool revoked = revokePending(group, pendingVotes, lesser, greater, index);
            require(revoked, "Revoke pending failed");

            uint256 unvotes = value.sub(pendingVotes);
            bool unvoted = election.revokeActive(group, unvotes, lesser, greater, index);
            require(unvoted, "Revoke unvotes failed");
        } else {
            bool revoked = revokePending(group, value, lesser, greater, index);
            require(revoked, "Revoke value failed");
        }

        staking.unlock(value);
        // todo 还需要register pool
        (uint256[] memory values, uint256[] memory timestamps) = staking.getPendingWithdrawals(address(this));
        uint256 length = values.length;
        require(length > 0 && length == timestamps.length && values[length-1] == value, "Unlock failed");
        return timestamps[length-1];
    }

    function getTotalVotes(address group) public view returns (uint256) {
        return election.getTotalVotesForGroupByAccount(group, address(this));
    }

    function withdraw() external onlyStakeManager returns (uint256[] memory, uint256[] memory) {
        uint256[] memory withdrawedValues;
        uint256[] memory withdrawedTimestamps;
        (uint256[] memory values, uint256[] memory timestamps) = staking.getPendingWithdrawals(address(this));
        uint256 length = values.length;
        require(length == timestamps.length, "Length of values should be equal to length of timestamps");
        if (length == 0) {
            return (withdrawedValues, withdrawedTimestamps);
        }

        for (uint256 i = 0; i < length; i = i.add(1)) {
            if (now >= timestamps[i]) {
                withdrawedValues.push(values[i]);
                withdrawedTimestamps.push(timestamps[i]);
            }
        }

        for (uint256 i = 0; i < withdrawedValues.length; i = i.add(1)) {
            staking.withdraw(0);
        }

        return (withdrawedValues, withdrawedTimestamps);
    }
}
