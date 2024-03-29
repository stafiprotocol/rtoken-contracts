pragma solidity 0.7.6;
// SPDX-License-Identifier: GPL-3.0-only

import {SafeERC20, IERC20, SafeMath} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/presets/ERC20PresetMinterPauser.sol";
import "../balancer-metastable-rate-providers/interfaces/IRateProvider.sol";
import "./Multisig.sol";

contract StakeERC20PortalWithRate is Multisig, IRateProvider {
    using SafeCast for *;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // ---- storage

    address public erc20TokenAddress;
    address public stakeUsePoolAddress;
    address public rTokenAddress;
    uint256 public minStakeAmount;
    uint256 public stakeRelayFee;
    uint256 public unstakeRelayFee;
    uint256 public unstakeFeeCommission; // decimals 18
    uint256 private rate; // decimals 18
    uint256 public rateChangeLimit; // decimals 18
    uint256 public totalUnstakeProtocolFee;
    bool public stakeSwitch;

    mapping(address => bool) public stakePoolAddressExist;

    // events
    event Stake(address staker, address stakePool, uint256 tokenAmount, uint256 rTokenAmount);
    event Unstake(address staker, address stakePool, uint256 tokenAmount, uint256 rTokenAmount, uint256 burnAmount);

    constructor(
        address[] memory _stakePoolAddressList,
        address[] memory _initialSubAccounts,
        address _erc20TokenAddress,
        address _rTokenAddress,
        address _stakeUsePoolAddress,
        uint256 _minStakeAmount,
        uint256 _stakeRelayFee,
        uint256 _unstakeRelayFee,
        uint256 _unstakeFeeCommission,
        uint256 _rate,
        uint256 _initialThreshold
    ) Multisig(_initialSubAccounts, _initialThreshold) {
        for (uint256 i = 0; i < _stakePoolAddressList.length; i++) {
            stakePoolAddressExist[_stakePoolAddressList[i]] = true;
        }

        require(stakePoolAddressExist[_stakeUsePoolAddress], "stake pool not exist");
        require(_rate > 0, "rate zero");

        erc20TokenAddress = _erc20TokenAddress;
        rTokenAddress = _rTokenAddress;
        minStakeAmount = _minStakeAmount;
        stakeUsePoolAddress = _stakeUsePoolAddress;
        stakeRelayFee = _stakeRelayFee;
        unstakeRelayFee = _unstakeRelayFee;
        unstakeFeeCommission = _unstakeFeeCommission;
        rate = _rate;
        rateChangeLimit = 1e15; // 0.1%
    }

    // ------ settings

    function addStakePool(address[] memory _stakePoolAddressList) external onlyOwner {
        for (uint256 i = 0; i < _stakePoolAddressList.length; i++) {
            stakePoolAddressExist[_stakePoolAddressList[i]] = true;
        }
    }

    function setStakeUsePool(address _stakeUsePoolAddress) external onlyOwner {
        require(stakePoolAddressExist[_stakeUsePoolAddress], "stake pool not exist");
        stakeUsePoolAddress = _stakeUsePoolAddress;
    }

    function rmStakePool(address _stakePoolAddress) external onlyOwner {
        delete stakePoolAddressExist[_stakePoolAddress];
    }

    function setMinStakeAmount(uint256 _minStakeAmount) external onlyOwner {
        minStakeAmount = _minStakeAmount;
    }

    function setStakeRelayFee(uint256 _stakeRelayFee) external onlyOwner {
        stakeRelayFee = _stakeRelayFee;
    }

    function setUnstakeRelayFee(uint256 _unstakeRelayFee) external onlyOwner {
        unstakeRelayFee = _unstakeRelayFee;
    }

    function setRate(uint256 _rate) external onlyOwner {
        require(_rate > 0, "rate zero");
        rate = _rate;
    }

    function setRateChangeLimit(uint256 _rateChangeLimit) external onlyOwner {
        rateChangeLimit = _rateChangeLimit;
    }

    function setUnstakeFeeCommission(uint256 _unstakeFeeCommission) external onlyOwner {
        unstakeFeeCommission = _unstakeFeeCommission;
    }

    function toggleStakeSwitch() external onlyOwner {
        stakeSwitch = !stakeSwitch;
    }

    // ----- getters

    function getRate() external view override returns (uint256) {
        return rate;
    }

    // ----- vote

    function voteRate(bytes32 _proposalId, uint256 _rate) public onlySubAccount {
        uint256 rateChange = _rate > rate ? _rate.sub(rate) : rate.sub(_rate);
        require(rateChange.mul(1e18).div(rate) < rateChangeLimit, "rate change over limit");

        Proposal memory proposal = proposals[_proposalId];

        require(uint256(proposal._status) <= 1, "proposal already executed");
        require(!_hasVoted(proposal, msg.sender), "already voted");

        if (proposal._status == ProposalStatus.Inactive) {
            proposal = Proposal({_status: ProposalStatus.Active, _yesVotes: 0, _yesVotesTotal: 0});
        }
        proposal._yesVotes = (proposal._yesVotes | subAccountBit(msg.sender)).toUint16();
        proposal._yesVotesTotal++;

        // Finalize if Threshold has been reached
        if (proposal._yesVotesTotal >= threshold) {
            rate = _rate;

            proposal._status = ProposalStatus.Executed;
            emit ProposalExecuted(_proposalId);
        }
        proposals[_proposalId] = proposal;
    }

    // ----- staker operation

    function stake(uint256 _amount) public payable {
        stakeWithPool(_amount, stakeUsePoolAddress);
    }

    function unstake(uint256 _rTokenAmount) public payable {
        unstakeWithPool(_rTokenAmount, stakeUsePoolAddress);
    }

    function stakeWithPool(uint256 _amount, address _stakePoolAddress) public payable {
        require(stakeSwitch, "stake not open");
        require(_amount >= minStakeAmount, "amount < minStakeAmount");
        require(msg.value >= stakeRelayFee, "fee not enough");
        require(stakePoolAddressExist[_stakePoolAddress], "stake pool not exist");

        uint256 rTokenAmount = _amount.mul(1e18).div(rate);

        // transfer token and mint rtoken
        IERC20(erc20TokenAddress).safeTransferFrom(msg.sender, _stakePoolAddress, _amount);
        ERC20PresetMinterPauser rToken = ERC20PresetMinterPauser(rTokenAddress);
        rToken.mint(msg.sender, rTokenAmount);

        // fee
        (bool success, ) = owner.call{value: msg.value}("");
        require(success, "failed to send fee");

        emit Stake(msg.sender, _stakePoolAddress, _amount, rTokenAmount);
    }

    function unstakeWithPool(uint256 _rTokenAmount, address _stakePoolAddress) public payable {
        require(stakeSwitch, "stake not open");
        require(_rTokenAmount >= 0, "amount zero");
        require(msg.value >= unstakeRelayFee, "relay fee not enough");
        require(stakePoolAddressExist[_stakePoolAddress], "stake pool not exist");

        uint256 unstakeFee = _rTokenAmount.mul(unstakeFeeCommission).div(1e18);
        uint256 leftRTokenAmount = _rTokenAmount.sub(unstakeFee);
        uint256 tokenAmount = leftRTokenAmount.mul(rate).div(1e18);

        // burn rtoken
        ERC20PresetMinterPauser rtoken = ERC20PresetMinterPauser(rTokenAddress);
        rtoken.burnFrom(msg.sender, leftRTokenAmount);

        // fee
        IERC20(rTokenAddress).safeTransferFrom(msg.sender, owner, unstakeFee);
        (bool success, ) = owner.call{value: msg.value}("");
        require(success, "failed to send fee");

        totalUnstakeProtocolFee = totalUnstakeProtocolFee.add(unstakeFee);

        emit Unstake(msg.sender, _stakePoolAddress, tokenAmount, _rTokenAmount, leftRTokenAmount);
    }
}
