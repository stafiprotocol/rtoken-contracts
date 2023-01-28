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

    enum TransferStatus {
        UnSubmit,
        Executed
    }

    mapping(bytes32 => TransferStatus) public _transferState;
    uint8 public _threshold;
    address public _erc20TokenAddress;
    uint256 public _timestamp;
    uint256 public _id;
    EnumerableSet.AddressSet subAccounts;

    constructor(
        address[] memory initialSubAccounts,
        uint256 initialThreshold,
        address erc20TokenAddress
    ) {
        require(
            initialSubAccounts.length >= initialThreshold &&
                initialThreshold > 0,
            "SP201/202"
        );
        _threshold = initialThreshold.toUint8();
        uint256 initialSubAccountCount = initialSubAccounts.length;
        for (uint256 i; i < initialSubAccountCount; i++) {
            subAccounts.add(initialSubAccounts[i]);
        }
        _erc20TokenAddress = erc20TokenAddress;
        _timestamp = block.timestamp;
        uint256 id;
        assembly {
            id := chainid()
        }
        _id = id;
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
            "SP201/202"
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

    function _hasVoted(uint256 yesVotes, address subAccount)
        private
        view
        returns (bool)
    {
        return (subAccountBit(subAccount) & yesVotes) > 0;
    }

    function checkSignatures(
        bytes32 dataHash,
        uint8[] memory vs,
        bytes32[] memory rs,
        bytes32[] memory ss
    ) private view returns (bool) {
        uint256 signum = vs.length;
        require(signum >= _threshold, "SP020");
        require(signum <= subAccounts.length(), "SP021");
        require(signum == rs.length && signum == ss.length, "SP022");

        uint256 yesVotes;
        for (uint256 i = 0; i < signum; i++) {
            //recover the address associated with the public key from elliptic curve signature or return zero on error
            address addr = ecrecover(dataHash, vs[i] + 27, rs[i], ss[i]);
            require(subAccounts.contains(addr), "SP023");
            require(!_hasVoted(yesVotes, addr), "SP024");
            yesVotes = yesVotes | subAccountBit(addr);
        }
        return true;
    }

    function batchTransfer(
        uint256 blockNumber,
        address[] memory tos,
        uint256[] memory values,
        uint8[] memory vs,
        bytes32[] memory rs,
        bytes32[] memory ss
    ) external onlySubAccount {
        require(tos.length == values.length, "SP300");
        bytes32 dataHash = keccak256(
            abi.encode(_timestamp, _id, blockNumber, tos, values)
        );
        require(_transferState[dataHash] == TransferStatus.UnSubmit, "SP301");
        require(checkSignatures(dataHash, vs, rs, ss), "SP025");

        for (uint256 i = 0; i < tos.length; i++) {
            IERC20(_erc20TokenAddress).safeTransfer(tos[i], values[i]);
        }
        _transferState[dataHash] = TransferStatus.Executed;
    }
}
