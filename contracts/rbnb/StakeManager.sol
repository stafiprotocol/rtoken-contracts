pragma solidity 0.7.6;
// SPDX-License-Identifier: GPL-3.0-only

import {SafeERC20, IERC20, SafeMath} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../balancer-metastable-rate-providers/interfaces/IRateProvider.sol";
import "./Multisig.sol";
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
    uint256 public protocolFeeCommission; // decimals 18
    uint256 public rateChangeLimit; // decimals 18
    bool public stakeSwitch;

    uint256 public currentEra;
    uint256 private rate; //need migrate decimals 18
    uint256 public totalRTokenSupply; //need migrate
    uint256 public totalProtocolFee; //need migrate

    uint256 public eraSeconds;
    uint256 nextUnstakeIndex;
    EnumerableSet.AddressSet bondedPools;
    mapping(address => PoolInfo) poolInfoOf;
    mapping(address => uint256) latestRewardTimestampOf;
    mapping(address => uint256) undistributedRewardOf;
    mapping(address => uint256) pendingDelegateOf;
    mapping(address => uint256) pendingUndelegateOf;
    mapping(uint256 => mapping(address => Operate)) pendingOperate;

    mapping(uint256 => UnstakeInfo) unstakeAtIndex;
    mapping(address => EnumerableSet.UintSet) unstakeOfUser;

    // events
    event Stake(address staker, address stakePool, uint256 tokenAmount, uint256 rTokenAmount);
    event Unstake(address staker, address stakePool, uint256 tokenAmount, uint256 rTokenAmount, uint256 burnAmount);

    function init(
        address[] calldata _initialSubAccounts,
        uint256 _initialThreshold,
        address _rTokenAddress,
        uint256 _minStakeAmount,
        uint256 _unstakeFeeCommission,
        address _stakePoolAddress,
        uint256 _bond, //need migrate
        uint256 _unbond, //need migrate
        uint256 _active, //need migrate
        uint256 _rate, //need migrate
        uint256 _totalRTokenSupply, //need migrate
        uint256 _totalProtocolFee //need migrate
    ) public {
        initMultisig(_initialSubAccounts, _initialThreshold);

        bondedPools.add(_stakePoolAddress);
        poolInfoOf[_stakePoolAddress] = PoolInfo({
            eraState: EraState.OperateAckExecuted,
            bond: _bond,
            unbond: _unbond,
            active: _active
        });

        require(_rate > 0, "rate zero");
        rate = _rate;

        rTokenAddress = _rTokenAddress;
        minStakeAmount = _minStakeAmount;
        unstakeFeeCommission = _unstakeFeeCommission;
        rateChangeLimit = 1e15; // 0.1%
        protocolFeeCommission = 1e17;
        totalRTokenSupply = _totalRTokenSupply;
        totalProtocolFee = _totalProtocolFee;
    }

    // ------ settings

    function addStakePool(address _stakePool) external onlyOwner {
        bondedPools.add(_stakePool);
    }

    function rmStakePool(address _stakePoolAddress) external onlyOwner {
        bondedPools.remove(_stakePoolAddress);
    }

    function setParams(
        uint256 _unstakeFeeCommission,
        uint256 _protocolFeeCommission,
        uint256 _minStakeAmount,
        uint256 _rateChangeLimit
    ) external onlyOwner {
        unstakeFeeCommission = _unstakeFeeCommission;
        protocolFeeCommission = _protocolFeeCommission;
        minStakeAmount = _minStakeAmount;
        rateChangeLimit = _rateChangeLimit;
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
        for (uint256 i = 0; i < poolLength; ++i) {
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

    function operate(
        uint256 _era,
        address _poolAddress,
        Action _action,
        address[] calldata _valList,
        uint256[] calldata _amountList
    ) public onlySubAccount {
        bytes32 proposalId = keccak256(abi.encodePacked("operate", _era, _poolAddress, _action, _valList, _amountList));
        Proposal memory proposal = checkProposal(proposalId);

        // Finalize if Threshold has been reached
        if (proposal._yesVotesTotal >= threshold) {
            exeOperate(_era, _poolAddress, _action, _valList, _amountList);

            proposal._status = ProposalStatus.Executed;
            emit ProposalExecuted(proposalId);
        }

        proposals[proposalId] = proposal;
    }

    function operateAck(
        uint256 _era,
        address _poolAddress,
        uint256[] calldata _successOpIndexList
    ) public onlySubAccount {
        bytes32 proposalId = keccak256(abi.encodePacked("operateAck", _era, _poolAddress, _successOpIndexList));
        Proposal memory proposal = checkProposal(proposalId);

        // Finalize if Threshold has been reached
        if (proposal._yesVotesTotal >= threshold) {
            exeOperateAck(_era, _poolAddress, _successOpIndexList);

            proposal._status = ProposalStatus.Executed;
            emit ProposalExecuted(proposalId);
        }

        proposals[proposalId] = proposal;
    }

    // ----- staker operation

    function stake(address _stakePoolAddress) public payable {
        require(stakeSwitch, "stake closed");
        require(msg.value >= minStakeAmount, "amount not match");
        require(bondedPools.contains(_stakePoolAddress), "pool not exist");

        uint256 rTokenAmount = msg.value.mul(1e18).div(rate);

        // update pool
        PoolInfo storage poolInfo = poolInfoOf[_stakePoolAddress];
        poolInfo.bond = poolInfo.bond.add(msg.value);
        poolInfo.active = poolInfo.active.add(msg.value);

        // transfer token
        (bool success, ) = _stakePoolAddress.call{value: msg.value}("");
        require(success, "transfer failed");

        // mint rtoken
        totalRTokenSupply = totalRTokenSupply.add(rTokenAmount);
        IERC20MintBurn(rTokenAddress).mint(msg.sender, rTokenAmount);

        emit Stake(msg.sender, _stakePoolAddress, msg.value, rTokenAmount);
    }

    function unstake(uint256 _rTokenAmount, address _stakePoolAddress) public payable {
        require(stakeSwitch, "stake closed");
        require(_rTokenAmount >= 0, "amount zero");
        require(bondedPools.contains(_stakePoolAddress), "pool not exist");

        uint256 unstakeFee = _rTokenAmount.mul(unstakeFeeCommission).div(1e18);
        uint256 leftRTokenAmount = _rTokenAmount.sub(unstakeFee);
        uint256 tokenAmount = leftRTokenAmount.mul(rate).div(1e18);

        // update pool
        PoolInfo storage poolInfo = poolInfoOf[_stakePoolAddress];
        poolInfo.unbond = poolInfo.unbond.add(tokenAmount);
        poolInfo.active = poolInfo.active.sub(tokenAmount);

        // burn rtoken
        IERC20MintBurn(rTokenAddress).burnFrom(msg.sender, leftRTokenAmount);
        totalRTokenSupply = totalRTokenSupply.sub(leftRTokenAmount);

        // fee
        totalProtocolFee = totalProtocolFee.add(unstakeFee);
        IERC20(rTokenAddress).safeTransferFrom(msg.sender, owner, unstakeFee);

        unstakeAtIndex[nextUnstakeIndex] = UnstakeInfo({era: currentEra, receiver: msg.sender, amount: tokenAmount});

        unstakeOfUser[msg.sender].add(nextUnstakeIndex);

        nextUnstakeIndex = nextUnstakeIndex.add(1);

        emit Unstake(msg.sender, _stakePoolAddress, tokenAmount, _rTokenAmount, leftRTokenAmount);
    }

    function claim(uint256[] calldata _unstakeIndexList) public {
        require(_unstakeIndexList.length > 0, "index empty");

        uint256 totalAmount;
        for (uint256 i = 0; i < _unstakeIndexList.length; ++i) {
            uint256 unstakeIndex = _unstakeIndexList[i];
            UnstakeInfo memory unstakeInfo = unstakeAtIndex[unstakeIndex];

            require(unstakeInfo.era <= currentEra, "not claimable");
            require(unstakeOfUser[msg.sender].remove(unstakeIndex), "already claimed");

            totalAmount = totalAmount.add(unstakeInfo.amount);
        }

        if (totalAmount > 0) {
            (bool result, ) = msg.sender.call{value: totalAmount}("");
            require(result, "call failed");
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

        uint256 totalOldActive;
        uint256 totalNewActive;
        for (uint256 i = 0; i < _poolAddressList.length; ++i) {
            require(_latestRewardTimestampList[i] < block.timestamp, "timestamp too big");
            require(
                _latestRewardTimestampList[i] >= latestRewardTimestampOf[_poolAddressList[i]],
                "timestamp too small"
            );
            address poolAddress = _poolAddressList[i];

            // update undistributedReward
            if (_undistributedRewardList[i] > 0) {
                undistributedRewardOf[poolAddress] = undistributedRewardOf[poolAddress].add(
                    _undistributedRewardList[i]
                );
            }

            PoolInfo memory poolInfo = poolInfoOf[poolAddress];

            // claim distributed reward
            uint256 claimedReward = IStakePool(poolAddress).checkAndClaimReward();
            if (claimedReward > 0) {
                undistributedRewardOf[poolAddress] = undistributedRewardOf[poolAddress].sub(claimedReward);
                pendingDelegateOf[poolAddress] = pendingDelegateOf[poolAddress].add(claimedReward);
            }

            // claim undelegated
            IStakePool(poolAddress).checkAndClaimUndelegated();

            // update pending value
            uint256 pendingDelegate = pendingDelegateOf[poolAddress].add(poolInfo.bond);
            uint256 pendingUndelegate = pendingUndelegateOf[poolAddress].add(poolInfo.unbond);

            uint256 diff = pendingDelegate > pendingUndelegate
                ? pendingDelegate - pendingUndelegate
                : pendingUndelegate - pendingDelegate;

            pendingDelegateOf[poolAddress] = pendingDelegate.sub(diff);
            pendingUndelegateOf[poolAddress] = pendingUndelegate.sub(diff);

            // cal total active
            uint256 poolNewActive = IStakePool(poolAddress)
                .getTotalDelegated()
                .add(pendingDelegateOf[poolAddress])
                .add(undistributedRewardOf[poolAddress])
                .sub(pendingUndelegateOf[poolAddress]);

            totalOldActive = totalOldActive.add(poolInfo.active);
            totalNewActive = totalNewActive.add(poolNewActive);

            // update pool state
            poolInfo.eraState = EraState.NewEraExecuted;
            poolInfo.active = poolNewActive;

            poolInfoOf[poolAddress] = poolInfo;
        }

        require(allPoolEraStateIs(EraState.NewEraExecuted, false), "missing pool");

        // cal protocol fee
        if (totalNewActive > totalOldActive) {
            uint256 rTokenProtocolFee = totalNewActive.sub(totalOldActive).mul(protocolFeeCommission).div(rate);
            totalProtocolFee = totalProtocolFee.add(rTokenProtocolFee);

            // mint rtoken
            totalRTokenSupply = totalRTokenSupply.add(rTokenProtocolFee);
            IERC20MintBurn(rTokenAddress).mint(owner, rTokenProtocolFee);
        }

        // uddate rate
        uint256 newRate = totalNewActive.mul(1e18).div(totalRTokenSupply);
        uint256 rateChange = newRate > rate ? newRate.sub(rate) : rate.sub(newRate);
        require(rateChange.mul(1e18).div(rate) < rateChangeLimit, "rate change over limit");
        // update era
        currentEra = _era;
    }

    function exeOperate(
        uint256 _era,
        address _poolAddress,
        Action _action,
        address[] calldata _valList,
        uint256[] calldata _amountList
    ) private {
        require(currentEra == _era, "era not match");
        require(poolInfoOf[_poolAddress].eraState == EraState.NewEraExecuted, "eraState not match");

        pendingOperate[_era][_poolAddress] = Operate({action: _action, valList: _valList, amountList: _amountList});

        if (_action == Action.Delegate) {
            IStakePool(_poolAddress).delegate(_valList, _amountList);
        } else if (_action == Action.Undelegate) {
            IStakePool(_poolAddress).undelegate(_valList, _amountList);
        }

        poolInfoOf[_poolAddress].eraState = EraState.OperateExecuted;
    }

    function exeOperateAck(uint256 _era, address _poolAddress, uint256[] calldata _successOpIndexList) private {
        require(currentEra == _era, "era not match");
        require(poolInfoOf[_poolAddress].eraState == EraState.OperateExecuted, "erState not match");

        Operate memory op = pendingOperate[_era][_poolAddress];
        if (op.action == Action.Delegate) {
            for (uint256 i = 0; i < _successOpIndexList.length; ++i) {
                pendingDelegateOf[_poolAddress] = pendingDelegateOf[_poolAddress].sub(
                    op.amountList[_successOpIndexList[i]]
                );
            }
        } else if (op.action == Action.Undelegate) {
            for (uint256 i = 0; i < _successOpIndexList.length; ++i) {
                uint256 undelegateAmount = op.amountList[_successOpIndexList[i]];
                uint256 pendingUndelegate = pendingUndelegateOf[_poolAddress];

                if (undelegateAmount > pendingUndelegate) {
                    pendingDelegateOf[_poolAddress] = pendingDelegateOf[_poolAddress].add(
                        undelegateAmount.sub(pendingUndelegate)
                    );
                    pendingUndelegateOf[_poolAddress] = 0;
                } else {
                    pendingUndelegateOf[_poolAddress] = pendingUndelegate.sub(undelegateAmount);
                }
            }
        }

        poolInfoOf[_poolAddress].eraState = EraState.OperateAckExecuted;
    }
}
