pragma solidity >=0.7.0 <0.9.0;
// SPDX-License-Identifier: GPL-3.0-only

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract StakePortal is Ownable {
    using SafeERC20 for IERC20;

    // Events
    event Stake(
        address staker,
        address stakePool,
        uint256 amount,
        uint8 chainId,
        bytes stafiRecipient,
        bytes destRecipient
    );

    address public erc20TokenAddress;
    uint256 public minAmount;
    uint256 public relayFee;
    mapping(address => bool) public stakePoolAddressExist;
    mapping(uint8 => bool) public chainIdExist;

    constructor(
        address[] memory _stakePoolAddressList,
        uint8[] memory _chainIdList,
        address _erc20TokenAddress,
        uint256 _minAmount,
        uint256 _relayFee
    ) {
        for (uint256 i = 0; i < _stakePoolAddressList.length; i++) {
            stakePoolAddressExist[_stakePoolAddressList[i]] = true;
        }

        for (uint256 i = 0; i < _chainIdList.length; i++) {
            chainIdExist[_chainIdList[i]] = true;
        }

        erc20TokenAddress = _erc20TokenAddress;
        minAmount = _minAmount;
        relayFee = _relayFee;
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

    function withdrawFee() external onlyOwner {
        (bool success, ) = msg.sender.call{value: address(this).balance}("");
        require(success, "failed to withdraw");
    }

    function stake(
        address _stakePoolAddress,
        uint256 _amount,
        uint8 _destChainId,
        bytes memory _stafiRecipient,
        bytes memory _destRecipient
    ) public payable {
        require(_amount >= minAmount, "amount < minAmount");
        require(msg.value >= relayFee, "relay fee not enough");
        require(
            stakePoolAddressExist[_stakePoolAddress],
            "stake pool not exist"
        );
        require(chainIdExist[_destChainId], "dest chain id not exit");

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
}
