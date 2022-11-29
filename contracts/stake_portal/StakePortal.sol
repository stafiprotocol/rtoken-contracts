pragma solidity >=0.7.0 <0.9.0;
// SPDX-License-Identifier: GPL-3.0-only

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract StakePortal is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Events
    event Stake(address staker, uint256 amount, bytes data);

    address public erc20TokenAddress;
    address public stakePoolAddress;
    uint256 public minAmount;

    constructor(
        address _erc20TokenAddress,
        address _stakePoolAddress,
        uint256 _minAmount
    ) {
        erc20TokenAddress = _erc20TokenAddress;
        stakePoolAddress = _stakePoolAddress;
        minAmount = _minAmount;
    }

    function setMinAmount(uint256 _minAmount) external onlyOwner {
        minAmount = _minAmount;
    }

    function stake(uint256 amount, bytes memory _data) public {
        require(amount >= minAmount, "amount < minAmount");

        uint256 balBefore = IERC20(erc20TokenAddress).balanceOf(
            stakePoolAddress
        );
        IERC20(erc20TokenAddress).safeTransferFrom(
            msg.sender,
            stakePoolAddress,
            amount
        );
        uint256 balAfter = IERC20(erc20TokenAddress).balanceOf(
            stakePoolAddress
        );

        require(balBefore.add(amount) == balAfter, "amount not match");

        emit Stake(msg.sender, amount, _data);
    }
}
