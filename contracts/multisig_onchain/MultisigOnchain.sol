pragma solidity 0.7.6;

// SPDX-License-Identifier: GPL-3.0-only

import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/EnumerableSet.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/SafeCast.sol";

contract MultisigOnchain is Ownable {
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

    uint8 public _threshold;
    EnumerableSet.AddressSet subAccounts;

    mapping(bytes32 => Proposal) public _proposals;

    function initialize(
        address[] memory initialSubAccounts,
        uint256 initialThreshold
    ) external {
        require(
            initialSubAccounts.length >= initialThreshold &&
                initialThreshold > 0,
            "invalid threshold"
        );
        require(_threshold == 0, "already initizlized");
        _threshold = initialThreshold.toUint8();
        uint256 initialSubAccountCount = initialSubAccounts.length;
        for (uint256 i; i < initialSubAccountCount; i++) {
            subAccounts.add(initialSubAccounts[i]);
        }
    }

    modifier onlySubAccount() {
        require(subAccounts.contains(msg.sender));
        _;
    }

    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    function addSubAccount(address subAccount) public onlyOwner {
        subAccounts.add(subAccount);
    }

    function removeSubAccount(address subAccount) public onlyOwner {
        subAccounts.remove(subAccount);
    }

    function changeThreshold(uint256 newThreshold) external onlyOwner {
        require(
            subAccounts.length() >= newThreshold && newThreshold > 0,
            "invalid threshold"
        );
        _threshold = newThreshold.toUint8();
    }

    function withdraw() public onlyOwner {
        (bool success, ) = msg.sender.call{value: address(this).balance}("");
        require(success, "transfer failed");
    }

    function getSubAccountIndex(
        address subAccount
    ) public view returns (uint256) {
        return subAccounts._inner._indexes[bytes32(uint256(subAccount))];
    }

    function subAccountBit(address subAccount) private view returns (uint256) {
        return uint256(1) << getSubAccountIndex(subAccount).sub(1);
    }

    function _hasVoted(
        Proposal memory proposal,
        address subAccount
    ) private view returns (bool) {
        return (subAccountBit(subAccount) & uint256(proposal._yesVotes)) > 0;
    }

    function exeTransactions(bytes memory transactions) public onlySubAccount {
        bytes32 dataHash = keccak256(transactions);
        Proposal memory proposal = _proposals[dataHash];

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
        if (proposal._yesVotesTotal >= _threshold) {
            multiSend(transactions);
            proposal._status = ProposalStatus.Executed;
        }
        _proposals[dataHash] = proposal;
    }

    /// @dev Sends multiple transactions and reverts all if one fails.
    /// @param transactions Encoded transactions. Each transaction is encoded as a packed bytes of
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
    function multiSend(bytes memory transactions) private {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let length := mload(transactions)
            let i := 0x20
            for {
                // Pre block is not used in "while mode"
            } lt(i, length) {
                // Post block is not used in "while mode"
            } {
                // First byte of the data is the operation.
                // We shift by 248 bits (256 - 8 [operation byte]) it right since mload will always load 32 bytes (a word).
                // This will also zero out unused data.
                let operation := shr(0xf8, mload(add(transactions, i)))
                // We offset the load address by 1 byte (operation byte)
                // We shift it right by 96 bits (256 - 160 [20 address bytes]) to right-align the data and zero out unused data.
                let to := shr(0x60, mload(add(transactions, add(i, 0x01))))
                // We offset the load address by 21 byte (operation byte + 20 address bytes)
                let value := mload(add(transactions, add(i, 0x15)))
                // We offset the load address by 53 byte (operation byte + 20 address bytes + 32 value bytes)
                let dataLength := mload(add(transactions, add(i, 0x35)))
                // We offset the load address by 85 byte (operation byte + 20 address bytes + 32 value bytes + 32 data length bytes)
                let data := add(transactions, add(i, 0x55))
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
