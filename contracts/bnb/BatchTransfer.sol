pragma solidity >=0.7.0 <0.9.0;

// SPDX-License-Identifier: GPL-3.0-only

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "./SafeCast.sol";

contract BatchTransfer is Ownable {
    using SafeCast for *;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeMath for uint256;

    //subAccount
    enum ProposalStatus {
        Inactive,
        Active,
        Executed
    }

    struct Proposal {
        ProposalStatus _status;
        uint40 _yesVotes; // bitmap, 40 maximum votes
        uint8 _yesVotesTotal;
    }
    mapping(bytes32 => Proposal) public _proposals;
    uint8 public _threshold;

    EnumerableSet.AddressSet subAccounts;

    constructor(address[] memory initialSubAccounts, uint256 initialThreshold) {
        _threshold = initialThreshold.toUint8();
        uint256 initialSubAccountCount = initialSubAccounts.length;
        for (uint256 i; i < initialSubAccountCount; i++) {
            subAccounts.add(initialSubAccounts[i]);
        }
    }

    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    // Fallback function is called when msg.data is not empty
    fallback() external payable {}

    modifier onlySubAccount() {
        require(subAccounts.contains(msg.sender));
        _;
    }

    function addSubAccount(address subAccount) public onlyOwner {
        subAccounts.add(subAccount);
    }

    function removeSubAccount(address subAccount) public onlyOwner {
        subAccounts.remove(subAccount);
    }

    function withdraw() public onlyOwner {
        msg.sender.call{value: address(this).balance}("");
    }

    function getSubAccountIndex(address subAccount)
        public
        view
        returns (uint256)
    {
        return subAccounts._inner._indexes[bytes32(uint256(subAccount))];
    }

    function subAccountBit(address subAccount) private view returns (uint256) {
        return uint256(1) << getSubAccountIndex(subAccount).sub(1);
    }

    function _hasVoted(Proposal memory proposal, address subAccount)
        private
        view
        returns (bool)
    {
        return (subAccountBit(subAccount) & uint256(proposal._yesVotes)) > 0;
    }

    function changeThreshold(uint256 newThreshold) external onlyOwner {
        _threshold = newThreshold.toUint8();
    }

    function batchTransfer(
        uint256 _block,
        address[] memory _tos,
        uint256[] memory _values
    ) public onlySubAccount {
        bytes32 dataHash = keccak256(abi.encodePacked(_block, _tos, _values));
        Proposal memory proposal = _proposals[dataHash];

        require(uint256(proposal._status) <= 1, "proposal already executed");
        require(!_hasVoted(proposal, msg.sender), "relayer already voted");

        if (proposal._status == ProposalStatus.Inactive) {
            proposal = Proposal({
                _status: ProposalStatus.Active,
                _yesVotes: 0,
                _yesVotesTotal: 0
            });
        }
        proposal._yesVotes = (proposal._yesVotes | subAccountBit(msg.sender))
            .toUint40();
        proposal._yesVotesTotal++;

        // Finalize if Threshold has been reached
        if (proposal._yesVotesTotal >= _threshold) {
            for (uint256 i = 0; i < _tos.length; i++) {
                (bool success, ) = _tos[i].call{value: _values[i]}("");
                require(success, "transfer failed");
            }
            proposal._status = ProposalStatus.Executed;
        }
        _proposals[dataHash] = proposal;
    }
}
