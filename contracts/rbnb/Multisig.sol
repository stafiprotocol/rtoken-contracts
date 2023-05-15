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
        require(_voters.length >= _initialThreshold && _initialThreshold > 0, "invalid threshold");
        require(threshold == 0, "already initizlized");
        threshold = _initialThreshold.toUint8();
        uint256 initialSubAccountCount = _voters.length;
        for (uint256 i; i < initialSubAccountCount; ++i) {
            voters.add(_voters[i]);
        }
        admin = msg.sender;
    }

    function transferOwnership(address _newOwner) public onlyAdmin {
        require(_newOwner != address(0), "new owner is the zero address");
        admin = _newOwner;
    }

    function addSubAccount(address _subAccount) public onlyAdmin {
        voters.add(_subAccount);
    }

    function removeSubAccount(address _subAccount) public onlyAdmin {
        voters.remove(_subAccount);
    }

    function changeThreshold(uint256 _newThreshold) external onlyAdmin {
        require(voters.length() >= _newThreshold && _newThreshold > 0, "invalid threshold");
        threshold = _newThreshold.toUint8();
    }

    function getSubAccountIndex(address _subAccount) public view returns (uint256) {
        return voters._inner._indexes[bytes32(uint256(_subAccount))];
    }

    function subAccountBit(address _subAccount) internal view returns (uint256) {
        return uint256(1) << getSubAccountIndex(_subAccount).sub(1);
    }

    function _hasVoted(Proposal memory _proposal, address _subAccount) internal view returns (bool) {
        return (subAccountBit(_subAccount) & uint256(_proposal._yesVotes)) > 0;
    }

    function hasVoted(bytes32 _proposalId, address _subAccount) public view returns (bool) {
        Proposal memory proposal = proposals[_proposalId];
        return _hasVoted(proposal, _subAccount);
    }
}
