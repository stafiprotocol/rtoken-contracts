pragma solidity 0.7.6;
// SPDX-License-Identifier: GPL-3.0-only

import {SafeERC20, IERC20, SafeMath} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/presets/ERC20PresetMinterPauser.sol";
import "../balancer-metastable-rate-providers/interfaces/IRateProvider.sol";
import "../stake-portal/Multisig.sol";

contract StakeManager is Multisig, IRateProvider {
    using SafeCast for *;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // ---- storage
    enum EraState {
        Undefined,
        NewEraExecuted,
        OperateExecuted,
        OperateAckExecuted
    }

    struct PoolInfo {
        uint256 currentEra;
        EraState eraState;
        uint256 bond;
        uint256 unbond;
        uint256 active;
    }

    struct Snapshot {
        uint256 bond;
        uint256 unbond;
        uint256 active;
    }

    address public rTokenAddress;
    uint256 public minStakeAmount;
    uint256 public unstakeFeeCommission; // decimals 18
    uint256 private rate; // decimals 18
    uint256 public rateChangeLimit; // decimals 18
    uint256 public totalUnstakeProtocolFee;
    bool public stakeSwitch;

    mapping(address => bool) public stakePoolAddressExist;

    uint256 public eraSeconds;
    mapping(address => PoolInfo) poolInfoOf;
    mapping(address => uint256) latestRewardTimestampOf;
    mapping(address => uint256) undistributedRewardOf;
    mapping(address => Snapshot) snapshotOf;
    mapping(address => uint256) pendingDelegateOf;
    mapping(address => uint256) pendingUndelegateOf;

    // events
    event Stake(address staker, address stakePool, uint256 tokenAmount, uint256 rTokenAmount);
    event Unstake(address staker, address stakePool, uint256 tokenAmount, uint256 rTokenAmount, uint256 burnAmount);

    constructor(
        address[] memory _stakePoolAddressList,
        address[] memory _initialSubAccounts,
        address _rTokenAddress,
        uint256 _minStakeAmount,
        uint256 _unstakeFeeCommission,
        uint256 _rate,
        uint256 _initialThreshold
    ) Multisig(_initialSubAccounts, _initialThreshold) {
        for (uint256 i = 0; i < _stakePoolAddressList.length; i++) {
            stakePoolAddressExist[_stakePoolAddressList[i]] = true;
        }

        require(_rate > 0, "rate zero");

        rTokenAddress = _rTokenAddress;
        minStakeAmount = _minStakeAmount;
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

    function rmStakePool(address _stakePoolAddress) external onlyOwner {
        delete stakePoolAddressExist[_stakePoolAddress];
    }

    function setMinStakeAmount(uint256 _minStakeAmount) external onlyOwner {
        minStakeAmount = _minStakeAmount;
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

    function newEra(
        uint256 _era,
        address _poolAddress,
        uint256 _undistributedReward,
        uint256 _latestRewardTimestamp
    ) public onlySubAccount {
        bytes32 proposalId = keccak256(abi.encodePacked("newEra", _era, _poolAddress));
        Proposal memory proposal = proposals[proposalId];

        require(uint256(proposal._status) <= 1, "proposal already executed");
        require(!_hasVoted(proposal, msg.sender), "already voted");

        if (proposal._status == ProposalStatus.Inactive) {
            proposal = Proposal({_status: ProposalStatus.Active, _yesVotes: 0, _yesVotesTotal: 0});
        }
        proposal._yesVotes = (proposal._yesVotes | subAccountBit(msg.sender)).toUint16();
        proposal._yesVotesTotal++;

        // Finalize if Threshold has been reached
        if (proposal._yesVotesTotal >= threshold) {
            uint256 currentEra = block.timestamp.div(eraSeconds);
            require(currentEra >= _era, "era not match");
            require(latestRewardTimestampOf[_poolAddress] <= _latestRewardTimestamp, "reward timestamp not match");

            if (_undistributedReward > 0) {
                undistributedRewardOf[_poolAddress] = undistributedRewardOf[_poolAddress].add(_undistributedReward);
            }

            PoolInfo memory poolInfo = poolInfoOf[_poolAddress];
            if (poolInfo.currentEra > 0) {
                require(_era == poolInfo.currentEra.add(1), "era not match");
                require(poolInfo.eraState == EraState.OperateAckExecuted, "state not match");
            }

            poolInfo.currentEra = _era;
            poolInfo.eraState = EraState.NewEraExecuted;
            snapshotOf[_poolAddress] = Snapshot({
                bond: poolInfo.bond,
                unbond: poolInfo.unbond,
                active: poolInfo.active
            });

            pendingDelegateOf[_poolAddress] = pendingDelegateOf[_poolAddress].add(poolInfo.bond);
            pendingUndelegateOf[_poolAddress] = pendingUndelegateOf[_poolAddress].add(poolInfo.unbond);

            proposal._status = ProposalStatus.Executed;
            emit ProposalExecuted(proposalId);
        }
        proposals[proposalId] = proposal;
    }

    // ----- staker operation

    function stake(address _stakePoolAddress) public payable {
        require(stakeSwitch, "stake not open");
        require(msg.value >= minStakeAmount, "amount < minStakeAmount");
        require(stakePoolAddressExist[_stakePoolAddress], "stake pool not exist");

        uint256 rTokenAmount = msg.value.mul(1e18).div(rate);

        // transfer token and mint rtoken
        (bool success, ) = _stakePoolAddress.call{value: msg.value}("");
        require(success, "transfer failed");
        ERC20PresetMinterPauser rToken = ERC20PresetMinterPauser(rTokenAddress);
        rToken.mint(msg.sender, rTokenAmount);

        emit Stake(msg.sender, _stakePoolAddress, msg.value, rTokenAmount);
    }

    function unstake(uint256 _rTokenAmount, address _stakePoolAddress) public payable {
        require(stakeSwitch, "stake not open");
        require(_rTokenAmount >= 0, "amount zero");
        require(stakePoolAddressExist[_stakePoolAddress], "stake pool not exist");

        uint256 unstakeFee = _rTokenAmount.mul(unstakeFeeCommission).div(1e18);
        uint256 leftRTokenAmount = _rTokenAmount.sub(unstakeFee);
        uint256 tokenAmount = leftRTokenAmount.mul(rate).div(1e18);

        // burn rtoken
        ERC20PresetMinterPauser rtoken = ERC20PresetMinterPauser(rTokenAddress);
        rtoken.burnFrom(msg.sender, leftRTokenAmount);

        // fee
        IERC20(rTokenAddress).safeTransferFrom(msg.sender, owner, unstakeFee);

        totalUnstakeProtocolFee = totalUnstakeProtocolFee.add(unstakeFee);

        emit Unstake(msg.sender, _stakePoolAddress, tokenAmount, _rTokenAmount, leftRTokenAmount);
    }
}
