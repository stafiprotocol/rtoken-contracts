pragma solidity 0.7.6;

// SPDX-License-Identifier: GPL-3.0-only

import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/EnumerableSet.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/SafeCast.sol";

contract MultisigOnchain {
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

    address public owner;
    uint8 public threshold;
    EnumerableSet.AddressSet subAccounts;

    mapping(bytes32 => Proposal) public proposals;

    event ProposalExecuted(bytes32 indexed proposalId);

    constructor() {
        // By setting the threshold it is not possible to call setup anymore,
        // so we create a Safe with 0 owners and threshold 1.
        // This is an unusable Safe, perfect for the singleton
        threshold = 1;
    }

    function initialize(
        address[] memory _initialSubAccounts,
        uint256 _initialThreshold
    ) external {
        require(
            _initialSubAccounts.length >= _initialThreshold &&
                _initialThreshold > 0,
            "invalid threshold"
        );
        require(threshold == 0, "already initizlized");
        threshold = _initialThreshold.toUint8();
        uint256 initialSubAccountCount = _initialSubAccounts.length;
        for (uint256 i; i < initialSubAccountCount; i++) {
            subAccounts.add(_initialSubAccounts[i]);
        }
        owner = msg.sender;
    }

    modifier onlySubAccount() {
        require(subAccounts.contains(msg.sender));
        _;
    }

    modifier onlyOwner() {
        require(owner == msg.sender, "caller is not the owner");
        _;
    }

    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    function transferOwnership(address _newOwner) public onlyOwner {
        require(_newOwner != address(0), "new owner is the zero address");
        owner = _newOwner;
    }

    function addSubAccount(address _subAccount) public onlyOwner {
        subAccounts.add(_subAccount);
    }

    function removeSubAccount(address _subAccount) public onlyOwner {
        subAccounts.remove(_subAccount);
    }

    function changeThreshold(uint256 _newThreshold) external onlyOwner {
        require(
            subAccounts.length() >= _newThreshold && _newThreshold > 0,
            "invalid threshold"
        );
        threshold = _newThreshold.toUint8();
    }

    function getSubAccountIndex(
        address _subAccount
    ) public view returns (uint256) {
        return subAccounts._inner._indexes[bytes32(uint256(_subAccount))];
    }

    function subAccountBit(address _subAccount) private view returns (uint256) {
        return uint256(1) << getSubAccountIndex(_subAccount).sub(1);
    }

    function _hasVoted(
        Proposal memory _proposal,
        address _subAccount
    ) private view returns (bool) {
        return (subAccountBit(_subAccount) & uint256(_proposal._yesVotes)) > 0;
    }

    function hasVoted(
        bytes32 _proposalId,
        address _subAccount
    ) public view returns (bool) {
        Proposal memory proposal = proposals[_proposalId];
        return _hasVoted(proposal, _subAccount);
    }

    function execTransactions(
        bytes32 _proposalId,
        bytes memory _transactions
    ) public onlySubAccount {
        Proposal memory proposal = proposals[_proposalId];

        require(uint256(proposal._status) <= 1, "proposal already executed");
        require(!_hasVoted(proposal, msg.sender), "already voted");

        if (proposal._status == ProposalStatus.Inactive) {
            proposal = Proposal({
                _status: ProposalStatus.Active,
                _yesVotes: 0,
                _yesVotesTotal: 0
            });
        }
        proposal._yesVotes = (proposal._yesVotes | subAccountBit(msg.sender))
            .toUint16();
        proposal._yesVotesTotal++;

        // Finalize if Threshold has been reached
        if (proposal._yesVotesTotal >= threshold) {
            multiSend(_transactions);
            proposal._status = ProposalStatus.Executed;
            emit ProposalExecuted(_proposalId);
        }
        proposals[_proposalId] = proposal;
    }

    /// @dev Sends multiple transactions and reverts all if one fails.
    /// @param _transactions Encoded transactions. Each transaction is encoded as a packed bytes of
    ///                     operation has to be uint8(0) in this version (=> 1 byte),
    ///                     to as a address (=> 20 bytes),
    ///                     value as a uint256 (=> 32 bytes),
    ///                     data length as a uint256 (=> 32 bytes),
    ///                     data as bytes.
    ///                     see abi.encodePacked for more information on packed encoding
    /// @notice The code is for most part the same as the normal MultiSend (to keep compatibility),
    ///         but reverts if a transaction tries to use a delegatecall.
    /// @notice This method is payable as delegatecalls keep the msg.value from the previous call
    ///         If the calling method (e.g. execTransaction) received ETH this would revert otherwise
    function multiSend(bytes memory _transactions) private {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let length := mload(_transactions)
            let i := 0x20
            for {
                // Pre block is not used in "while mode"
            } lt(i, length) {
                // Post block is not used in "while mode"
            } {
                // First byte of the data is the operation.
                // We shift by 248 bits (256 - 8 [operation byte]) it right since mload will always load 32 bytes (a word).
                // This will also zero out unused data.
                let operation := shr(0xf8, mload(add(_transactions, i)))
                // We offset the load address by 1 byte (operation byte)
                // We shift it right by 96 bits (256 - 160 [20 address bytes]) to right-align the data and zero out unused data.
                let to := shr(0x60, mload(add(_transactions, add(i, 0x01))))
                // We offset the load address by 21 byte (operation byte + 20 address bytes)
                let value := mload(add(_transactions, add(i, 0x15)))
                // We offset the load address by 53 byte (operation byte + 20 address bytes + 32 value bytes)
                let dataLength := mload(add(_transactions, add(i, 0x35)))
                // We offset the load address by 85 byte (operation byte + 20 address bytes + 32 value bytes + 32 data length bytes)
                let data := add(_transactions, add(i, 0x55))
                let success := 0
                switch operation
                case 0 {
                    success := call(gas(), to, value, data, dataLength, 0, 0)
                }
                // This version does not allow delegatecalls
                case 1 {
                    revert(0, 0)
                }
                if eq(success, 0) {
                    revert(0, 0)
                }
                // Next entry starts at 85 byte + data length
                i := add(i, add(0x55, dataLength))
            }
        }
    }
}
