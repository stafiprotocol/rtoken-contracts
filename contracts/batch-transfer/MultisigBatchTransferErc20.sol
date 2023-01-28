pragma solidity >=0.7.0 <0.9.0;

// SPDX-License-Identifier: GPL-3.0-only

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "./SafeCast.sol";

contract BatchTransfer is Ownable {
    using SafeCast for *;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

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
    address public _erc20TokenAddress;

    EnumerableSet.AddressSet subAccounts;

    constructor(
        address[] memory initialSubAccounts,
        uint256 initialThreshold,
        address erc20TokenAddress
    ) {
        require(
            initialSubAccounts.length >= initialThreshold &&
                initialThreshold > 0,
            "invalid threshold"
        );
        _threshold = initialThreshold.toUint8();
        uint256 initialSubAccountCount = initialSubAccounts.length;
        for (uint256 i; i < initialSubAccountCount; i++) {
            subAccounts.add(initialSubAccounts[i]);
        }
        _erc20TokenAddress = erc20TokenAddress;
    }

    modifier onlySubAccount() {
        require(subAccounts.contains(msg.sender));
        _;
    }

    function addSubAccount(address subAccount) external onlyOwner {
        subAccounts.add(subAccount);
    }

    function removeSubAccount(address subAccount) external onlyOwner {
        subAccounts.remove(subAccount);
    }

    function changeThreshold(uint256 newThreshold) external onlyOwner {
        require(
            subAccounts.length() >= newThreshold && newThreshold > 0,
            "invalid threshold"
        );
        _threshold = newThreshold.toUint8();
    }

    function changeErc20TokenAddress(address erc20TokenAddress)
        external
        onlyOwner
    {
        _erc20TokenAddress = erc20TokenAddress;
    }

    function withdraw() external onlyOwner {
        uint256 bal = IERC20(_erc20TokenAddress).balanceOf(address(this));
        IERC20(_erc20TokenAddress).safeTransfer(msg.sender, bal);
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

    function batchTransfer(
        uint256 _block,
        address[] memory _tos,
        uint256[] memory _values
    ) public onlySubAccount {
        require(
            _tos.length == _values.length,
            "_tos len must equal to _values"
        );
        bytes32 dataHash = keccak256(abi.encode(_block, _tos, _values));
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
            .toUint40();
        proposal._yesVotesTotal++;

        // Finalize if Threshold has been reached
        if (proposal._yesVotesTotal >= _threshold) {
            for (uint256 i = 0; i < _tos.length; i++) {
                IERC20(_erc20TokenAddress).safeTransfer(_tos[i], _values[i]);
            }
            proposal._status = ProposalStatus.Executed;
        }
        _proposals[dataHash] = proposal;
    }
}
