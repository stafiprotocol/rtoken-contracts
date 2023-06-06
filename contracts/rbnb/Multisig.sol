pragma solidity 0.7.6;

// SPDX-License-Identifier: GPL-3.0-only

import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/EnumerableSet.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/SafeCast.sol";

contract Multisig {
    using SafeCast for *;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeMath for uint256;

    enum ProposalStatus {
        Inactive,
        Active,
        Executed
    }

    struct Proposal {
        ProposalStatus _status;
        uint16 _yesVotes; // bitmap, 16 maximum votes
        uint8 _yesVotesTotal;
    }

    address public admin;
    uint8 public threshold;
    EnumerableSet.AddressSet voters;

    mapping(bytes32 => Proposal) public proposals;

    event ProposalExecuted(bytes32 indexed proposalId);

    modifier onlyVoter() {
        require(voters.contains(msg.sender));
        _;
    }

    modifier onlyAdmin() {
        require(admin == msg.sender, "caller is not the owner");
        _;
    }

    function initMultisig(address[] memory _voters, uint256 _initialThreshold) public {
        require(threshold == 0, "already initizlized");
        require(_voters.length >= _initialThreshold && _initialThreshold > _voters.length.div(2), "invalid threshold");
        require(_voters.length <= 16, "too much voters");

        threshold = _initialThreshold.toUint8();
        uint256 initialVoterCount = _voters.length;
        for (uint256 i; i < initialVoterCount; ++i) {
            voters.add(_voters[i]);
        }
        admin = msg.sender;
    }

    function transferOwnership(address _newOwner) public onlyAdmin {
        require(_newOwner != address(0), "zero address");

        admin = _newOwner;
    }

    function addVoter(address _voter) public onlyAdmin {
        require(voters.length() < 16, "too much voters");
        require(threshold > (voters.length().add(1)).div(2), "invalid threshold");

        voters.add(_voter);
    }

    function removeVoter(address _voter) public onlyAdmin {
        require(voters.length() > threshold, "voters not enough");

        voters.remove(_voter);
    }

    function changeThreshold(uint256 _newThreshold) external onlyAdmin {
        require(voters.length() >= _newThreshold && _newThreshold > voters.length().div(2), "invalid threshold");

        threshold = _newThreshold.toUint8();
    }

    function getVoterIndex(address _voter) public view returns (uint256) {
        return voters._inner._indexes[bytes32(uint256(_voter))];
    }

    function voterBit(address _voter) internal view returns (uint256) {
        return uint256(1) << getVoterIndex(_voter).sub(1);
    }

    function _hasVoted(Proposal memory _proposal, address _voter) internal view returns (bool) {
        return (voterBit(_voter) & uint256(_proposal._yesVotes)) > 0;
    }

    function hasVoted(bytes32 _proposalId, address _voter) public view returns (bool) {
        Proposal memory proposal = proposals[_proposalId];
        return _hasVoted(proposal, _voter);
    }

    function _checkProposal(bytes32 _proposalId) internal view returns (Proposal memory proposal) {
        proposal = proposals[_proposalId];

        require(uint256(proposal._status) <= 1, "proposal already executed");
        require(!_hasVoted(proposal, msg.sender), "already voted");

        if (proposal._status == ProposalStatus.Inactive) {
            proposal = Proposal({_status: ProposalStatus.Active, _yesVotes: 0, _yesVotesTotal: 0});
        }
        proposal._yesVotes = (proposal._yesVotes | voterBit(msg.sender)).toUint16();
        proposal._yesVotesTotal++;
    }
}
