pragma solidity >=0.7.0 <0.9.0;
// SPDX-License-Identifier: GPL-3.0-only

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

contract StakePortal {
    using SafeERC20 for IERC20;

    // Events
    event Stake(
        address staker,
        address stakePool,
        uint256 amount,
        uint8 chainId,
        bytes32 stafiRecipient,
        address destRecipient
    );
    event RecoverStake(bytes32 txHash, bytes32 stafiRecipient);

    address public erc20TokenAddress;
    uint256 public minAmount;
    uint256 public relayFee;
    address public owner;
    bool public stakeSwitch;
    bool public initialized;

    mapping(address => bool) public stakePoolAddressExist;
    mapping(uint8 => bool) public chainIdExist;

    modifier onlyOwner() {
        require(owner == msg.sender, "caller is not the owner");
        _;
    }

    function initialize(
        address[] memory _stakePoolAddressList,
        uint8[] memory _chainIdList,
        address _erc20TokenAddress,
        uint256 _minAmount,
        uint256 _relayFee
    ) external {
        require(!initialized, "already initialized");
        for (uint256 i = 0; i < _stakePoolAddressList.length; i++) {
            stakePoolAddressExist[_stakePoolAddressList[i]] = true;
        }

        for (uint256 i = 0; i < _chainIdList.length; i++) {
            chainIdExist[_chainIdList[i]] = true;
        }

        erc20TokenAddress = _erc20TokenAddress;
        minAmount = _minAmount;
        relayFee = _relayFee;
        owner = msg.sender;
        stakeSwitch = true;
        initialized = true;
    }

    function transferOwnership(address _newOwner) public onlyOwner {
        require(_newOwner != address(0), "new owner is the zero address");
        owner = _newOwner;
    }

    function addStakePool(
        address[] memory _stakePoolAddressList
    ) external onlyOwner {
        for (uint256 i = 0; i < _stakePoolAddressList.length; i++) {
            stakePoolAddressExist[_stakePoolAddressList[i]] = true;
        }
    }

    function rmStakePool(address _stakePoolAddress) external onlyOwner {
        delete stakePoolAddressExist[_stakePoolAddress];
    }

    function addChainId(uint8[] memory _chaindIdList) external onlyOwner {
        for (uint256 i = 0; i < _chaindIdList.length; i++) {
            chainIdExist[_chaindIdList[i]] = true;
        }
    }

    function rmChainId(uint8 _chaindId) external onlyOwner {
        delete chainIdExist[_chaindId];
    }

    function setMinAmount(uint256 _minAmount) external onlyOwner {
        minAmount = _minAmount;
    }

    function setRelayFee(uint256 _relayFee) external onlyOwner {
        relayFee = _relayFee;
    }

    function toggleSwitch() external onlyOwner {
        stakeSwitch = !stakeSwitch;
    }

    function withdrawFee() external onlyOwner {
        (bool success, ) = msg.sender.call{value: address(this).balance}("");
        require(success, "failed to withdraw");
    }

    function stake(
        address _stakePoolAddress,
        uint256 _amount,
        uint8 _destChainId,
        bytes32 _stafiRecipient,
        address _destRecipient
    ) public payable {
        require(stakeSwitch, "stake not open");
        require(_amount >= minAmount, "amount < minAmount");
        require(msg.value >= relayFee, "relay fee not enough");
        require(
            stakePoolAddressExist[_stakePoolAddress],
            "stake pool not exist"
        );
        require(chainIdExist[_destChainId], "dest chain id not exit");
        require(
            _stafiRecipient != bytes32(0) && _destRecipient != address(0),
            "wrong recipient"
        );

        IERC20(erc20TokenAddress).safeTransferFrom(
            msg.sender,
            _stakePoolAddress,
            _amount
        );

        emit Stake(
            msg.sender,
            _stakePoolAddress,
            _amount,
            _destChainId,
            _stafiRecipient,
            _destRecipient
        );
    }

    function recoverStake(bytes32 _txHash, bytes32 _stafiRecipient) public {
        require(
            _txHash != bytes32(0) && _stafiRecipient != bytes32(0),
            "wrong txHash or recipient"
        );

        emit RecoverStake(_txHash, _stafiRecipient);
    }
}
