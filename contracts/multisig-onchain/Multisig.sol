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
        ProposalStatus status;
        uint16 yesVotes; // bitmap, 16 maximum votes
        uint8 yesVotesTotal;
        address to;
        uint256 value;
        string methodSignature;
        bytes encodedParams;
    }

    uint8 public threshold;
    EnumerableSet.AddressSet voters;

    uint256 public nextProposalId;
    mapping(uint256 => Proposal) public proposals;

    event ProposalExecuted(uint256 indexed proposalId);

    constructor(address[] memory _voters, uint256 _initialThreshold) {
        require(
            _initialThreshold > 1 && _initialThreshold > _voters.length.div(2) && _voters.length >= _initialThreshold,
            "invalid threshold"
        );
        require(_voters.length <= 16, "too much voters");

        threshold = _initialThreshold.toUint8();
        for (uint256 i; i < _voters.length; ++i) {
            voters.add(_voters[i]);
        }
    }

    // ---modifier---

    modifier onlyVoter() {
        require(voters.contains(msg.sender));
        _;
    }

    modifier onlyMultisig() {
        require(msg.sender == address(this), "caller is not multisig");
        _;
    }

    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    // ---getter---

    function hasVoted(uint256 _proposalId, address _voter) public view returns (bool) {
        Proposal storage proposal = proposals[_proposalId];
        return _hasVoted(proposal.yesVotes, _voter);
    }

    function getVoters() external view returns (address[] memory list) {
        list = new address[](voters.length());
        for (uint256 i = 0; i < voters.length(); ++i) {
            list[i] = voters.at(i);
        }
    }

    // ---settings---

    function addVoter(address _voter) public onlyMultisig {
        require(voters.length() < 16, "too much voters");
        require(threshold > (voters.length().add(1)).div(2), "invalid threshold");

        voters.add(_voter);
    }

    function removeVoter(address _voter) public onlyMultisig {
        require(voters.length() > threshold, "voters not enough");

        voters.remove(_voter);
    }

    function changeThreshold(uint256 _newThreshold) external onlyMultisig {
        require(voters.length() >= _newThreshold && _newThreshold > voters.length().div(2), "invalid threshold");

        threshold = _newThreshold.toUint8();
    }

    // ---vote---

    function submitProposal(
        address _to,
        uint256 _value,
        string calldata _methodSignature,
        bytes calldata _encodedParams
    ) external onlyVoter {
        Proposal memory newProposal = Proposal({
            status: ProposalStatus.Active,
            yesVotes: 0,
            yesVotesTotal: 1,
            to: _to,
            value: _value,
            methodSignature: _methodSignature,
            encodedParams: _encodedParams
        });
        newProposal.yesVotes = (newProposal.yesVotes | _voterBit(msg.sender)).toUint16();

        proposals[nextProposalId] = newProposal;
        nextProposalId = nextProposalId.add(1);
    }

    function voteProposal(uint256 _proposalId) external onlyVoter {
        Proposal storage proposal = proposals[_proposalId];

        require(proposal.status == ProposalStatus.Active, "proposal not active");
        require(!_hasVoted(proposal.yesVotes, msg.sender), "already voted");

        proposal.yesVotes = (proposal.yesVotes | _voterBit(msg.sender)).toUint16();
        proposal.yesVotesTotal++;

        if (proposal.yesVotes >= threshold) {
            bytes memory callData;
            if (bytes(proposal.methodSignature).length != 0) {
                callData = abi.encodePacked(bytes4(keccak256(bytes(proposal.methodSignature))), proposal.encodedParams);
            }

            (bool success, ) = proposal.to.call{value: proposal.value}(callData);
            require(success, "call failed");

            proposal.status == ProposalStatus.Executed;

            emit ProposalExecuted(_proposalId);
        }
    }

    // ---helper---

    function _hasVoted(uint16 _yesVotes, address _voter) private view returns (bool) {
        return (_voterBit(_voter) & uint256(_yesVotes)) > 0;
    }

    function _voterBit(address _voter) private view returns (uint256) {
        return uint256(1) << _getVoterIndex(_voter).sub(1);
    }

    function _getVoterIndex(address _voter) public view returns (uint256) {
        return voters._inner._indexes[bytes32(uint256(_voter))];
    }
}
