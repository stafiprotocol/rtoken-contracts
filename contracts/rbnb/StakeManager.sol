pragma solidity 0.7.6;
// SPDX-License-Identifier: GPL-3.0-only

import {SafeERC20, IERC20, SafeMath} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../balancer-metastable-rate-providers/interfaces/IRateProvider.sol";
import "../stake-portal/Multisig.sol";
import "./Types.sol";
import "./IStakePool.sol";
import "./IERC20MintBurn.sol";

contract StakeManager is Multisig, IRateProvider {
    using SafeCast for *;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    // ---- storage

    address public rTokenAddress;
    uint256 public minStakeAmount;
    uint256 public unstakeFeeCommission; // decimals 18
    uint256 public rateChangeLimit; // decimals 18
    bool public stakeSwitch;

    uint256 public currentEra;
    EraState public currentEraState;
    uint256 private rate; //need migrate decimals 18
    uint256 public totalRTokenSupply; //need migrate
    uint256 public totalProtocolFee; //need migrate

    uint256 public eraSeconds;
    uint256 nextUnstakeIndex;
    EnumerableSet.AddressSet bondedPools;
    mapping(address => PoolInfo) poolInfoOf;
    mapping(address => uint256) latestRewardTimestampOf;
    mapping(address => uint256) undistributedRewardOf;
    mapping(address => Snapshot) snapshotOf;
    mapping(address => uint256) pendingDelegateOf;
    mapping(address => uint256) pendingUndelegateOf;

    mapping(uint256 => UnstakeInfo) unstakeAtIndex;
    mapping(address => EnumerableSet.UintSet) unstakeOfUser;

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
            bondedPools.add(_stakePoolAddressList[i]);
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
            bondedPools.add(_stakePoolAddressList[i]);
        }
    }

    function rmStakePool(address _stakePoolAddress) external onlyOwner {
        bondedPools.remove(_stakePoolAddress);
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

    function allPoolEraStateIs(EraState eraState, bool skipUninitialized) public view returns (bool) {
        uint256 poolLength = bondedPools.length();
        for (uint256 i = 0; i < poolLength; i++) {
            PoolInfo memory poolInfo = poolInfoOf[bondedPools.at(i)];
            if (skipUninitialized && poolInfo.eraState == EraState.Uninitialized) {
                continue;
            }
            if (poolInfo.eraState != eraState) {
                return false;
            }
        }
        return true;
    }

    // ----- vote

    function newEra(
        uint256 _era,
        address[] calldata _poolAddressList,
        uint256[] calldata _undistributedRewardList,
        uint256[] calldata _latestRewardTimestampList
    ) public onlySubAccount {
        bytes32 proposalId = keccak256(
            abi.encodePacked("newEra", _era, _poolAddressList, _undistributedRewardList, _latestRewardTimestampList)
        );
        Proposal memory proposal = checkProposal(proposalId);

        // Finalize if Threshold has been reached
        if (proposal._yesVotesTotal >= threshold) {
            exeNewEra(_era, _poolAddressList, _undistributedRewardList, _latestRewardTimestampList);

            proposal._status = ProposalStatus.Executed;
            emit ProposalExecuted(proposalId);
        }

        proposals[proposalId] = proposal;
    }

    // ----- staker operation

    function stake(address _stakePoolAddress) public payable {
        require(stakeSwitch, "stake not open");
        require(msg.value >= minStakeAmount, "amount < minStakeAmount");
        require(bondedPools.contains(_stakePoolAddress), "stake pool not exist");

        uint256 rTokenAmount = msg.value.mul(1e18).div(rate);

        // update pool
        PoolInfo storage poolInfo = poolInfoOf[_stakePoolAddress];
        poolInfo.bond = poolInfo.bond.add(msg.value);
        poolInfo.active = poolInfo.active.add(msg.value);

        // transfer token and mint rtoken
        (bool success, ) = _stakePoolAddress.call{value: msg.value}("");
        require(success, "transfer failed");
        IERC20MintBurn(rTokenAddress).mint(msg.sender, rTokenAmount);

        emit Stake(msg.sender, _stakePoolAddress, msg.value, rTokenAmount);
    }

    function unstake(uint256 _rTokenAmount, address _stakePoolAddress) public payable {
        require(stakeSwitch, "stake not open");
        require(_rTokenAmount >= 0, "amount zero");
        require(bondedPools.contains(_stakePoolAddress), "stake pool not exist");

        uint256 unstakeFee = _rTokenAmount.mul(unstakeFeeCommission).div(1e18);
        uint256 leftRTokenAmount = _rTokenAmount.sub(unstakeFee);
        uint256 tokenAmount = leftRTokenAmount.mul(rate).div(1e18);

        // update pool
        PoolInfo storage poolInfo = poolInfoOf[_stakePoolAddress];
        poolInfo.unbond = poolInfo.unbond.add(tokenAmount);
        poolInfo.active = poolInfo.active.sub(tokenAmount);

        // burn rtoken
        IERC20MintBurn(rTokenAddress).burnFrom(msg.sender, leftRTokenAmount);

        // fee
        IERC20(rTokenAddress).safeTransferFrom(msg.sender, owner, unstakeFee);

        totalProtocolFee = totalProtocolFee.add(unstakeFee);

        unstakeAtIndex[nextUnstakeIndex] = UnstakeInfo({era: currentEra, receiver: msg.sender, amount: tokenAmount});

        unstakeOfUser[msg.sender].add(nextUnstakeIndex);

        nextUnstakeIndex = nextUnstakeIndex.add(1);

        emit Unstake(msg.sender, _stakePoolAddress, tokenAmount, _rTokenAmount, leftRTokenAmount);
    }

    function claim(uint256[] calldata _unstakeIndexList) public {
        require(_unstakeIndexList.length > 0, "index list empty");

        uint256 totalAmount;
        for (uint256 i = 0; i < _unstakeIndexList.length; i++) {
            uint256 unstakeIndex = _unstakeIndexList[i];
            UnstakeInfo memory unstakeInfo = unstakeAtIndex[unstakeIndex];

            require(unstakeInfo.era <= currentEra, "not claimable");
            require(unstakeOfUser[msg.sender].remove(unstakeIndex), "already claimed");

            totalAmount = totalAmount.add(unstakeInfo.amount);
        }

        if (totalAmount > 0) {
            (bool result, ) = msg.sender.call{value: totalAmount}("");
            require(result, "user failed to claim ETH");
        }
    }

    // ----- helper

    function checkProposal(bytes32 _proposalId) private view returns (Proposal memory proposal) {
        proposal = proposals[_proposalId];

        require(uint256(proposal._status) <= 1, "proposal already executed");
        require(!_hasVoted(proposal, msg.sender), "already voted");

        if (proposal._status == ProposalStatus.Inactive) {
            proposal = Proposal({_status: ProposalStatus.Active, _yesVotes: 0, _yesVotesTotal: 0});
        }
        proposal._yesVotes = (proposal._yesVotes | subAccountBit(msg.sender)).toUint16();
        proposal._yesVotesTotal++;
    }

    function exeNewEra(
        uint256 _era,
        address[] calldata _poolAddressList,
        uint256[] calldata _undistributedRewardList,
        uint256[] calldata _latestRewardTimestampList
    ) private {
        require(block.timestamp.div(eraSeconds) >= _era, "not match calEra");
        require(currentEra == 0 || _era == currentEra.add(1), "not match currentEra");
        require(allPoolEraStateIs(EraState.OperateAckExecuted, true), "era not continuable");

        for (uint256 i = 0; i < _poolAddressList.length; i++) {
            require(_latestRewardTimestampList[i] < block.timestamp, "timestamp not match");
            require(
                latestRewardTimestampOf[_poolAddressList[i]] <= _latestRewardTimestampList[i],
                "reward timestamp not match"
            );
            address poolAddress = _poolAddressList[i];

            // update undistributedReward
            if (_undistributedRewardList[i] > 0) {
                undistributedRewardOf[poolAddress] = undistributedRewardOf[poolAddress].add(
                    _undistributedRewardList[i]
                );
            }

            PoolInfo memory poolInfo = poolInfoOf[poolAddress];

            // update pool state
            poolInfo.eraState = EraState.NewEraExecuted;
            poolInfoOf[poolAddress] = poolInfo;

            // update snapshot
            snapshotOf[poolAddress] = Snapshot({
                era: _era,
                bond: poolInfo.bond,
                unbond: poolInfo.unbond,
                active: poolInfo.active
            });

            // update pending value
            pendingDelegateOf[poolAddress] = pendingDelegateOf[poolAddress].add(poolInfo.bond);
            pendingUndelegateOf[poolAddress] = pendingUndelegateOf[poolAddress].add(poolInfo.unbond);

            // claim distributed reward
            uint256 claimedReward = IStakePool(poolAddress).checkAndClaimReward();
            if (claimedReward > 0) {
                undistributedRewardOf[poolAddress] = undistributedRewardOf[poolAddress].sub(claimedReward);
                pendingDelegateOf[poolAddress] = pendingDelegateOf[poolAddress].add(claimedReward);
            }

            // claim undelegated
            IStakePool(poolAddress).checkAndClaimUndelegated();
        }

        require(allPoolEraStateIs(EraState.NewEraExecuted, false), "missing pool");

        currentEra = _era;
        currentEraState = EraState.NewEraExecuted;
    }
}
