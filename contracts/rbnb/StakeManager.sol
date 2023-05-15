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

    bool public stakeSwitch;

    // params
    address public rTokenAddress;
    uint256 public minStakeAmount;
    uint256 public unstakeFeeCommission; // decimals 18
    uint256 public protocolFeeCommission; // decimals 18
    uint256 public rateChangeLimit; // decimals 18
    uint256 public transferGas;
    uint256 public eraSeconds;

    // era state
    uint256 public currentEra; // need migrate
    uint256 private rate; // need migrate decimals 18
    uint256 public totalRTokenSupply; // need migrate
    uint256 public totalProtocolFee; // need migrate

    EnumerableSet.AddressSet bondedPools;
    mapping(address => PoolInfo) poolInfoOf;
    mapping(address => EnumerableSet.AddressSet) validatorsOf;
    mapping(address => uint256) latestRewardTimestampOf;
    mapping(address => uint256) undistributedRewardOf;
    mapping(address => uint256) pendingDelegateOf;
    mapping(address => uint256) pendingUndelegateOf;
    mapping(uint256 => mapping(address => Operate)) pendingOperate; //era=>(pool=>operate)

    // unstake info
    uint256 nextUnstakeIndex;
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
        address _validator,
        uint256 _bond, // need migrate
        uint256 _unbond, // need migrate
        uint256 _active, // need migrate
        uint256 _rate, // need migrate
        uint256 _totalRTokenSupply, // need migrate
        uint256 _totalProtocolFee, // need migrate
        uint256 _era // need migrate
    ) public {
        initMultisig(_initialSubAccounts, _initialThreshold);

        rTokenAddress = _rTokenAddress;
        minStakeAmount = _minStakeAmount;
        unstakeFeeCommission = _unstakeFeeCommission;

        bondedPools.add(_stakePoolAddress);
        validatorsOf[_stakePoolAddress].add(_validator);
        poolInfoOf[_stakePoolAddress] = PoolInfo({
            eraState: EraState.OperateAckExecuted,
            bond: _bond,
            unbond: _unbond,
            active: _active
        });
        rate = _rate;
        totalRTokenSupply = _totalRTokenSupply;
        totalProtocolFee = _totalProtocolFee;
        currentEra = _era;

        rateChangeLimit = 1e15; // 0.1%
        protocolFeeCommission = 1e17;
        transferGas = 2300;
    }

    // ------ settings

    function addStakePool(address _stakePool) external onlyAdmin {
        require(allPoolEraStateIs(EraState.OperateAckExecuted, true), "eraState not match");
        bondedPools.add(_stakePool);
    }

    function rmStakePool(address _stakePool) external onlyAdmin {
        PoolInfo memory poolInfo = poolInfoOf[_stakePool];
        require(allPoolEraStateIs(EraState.OperateAckExecuted, true), "eraState not match");
        require(poolInfo.active == 0 && poolInfo.bond == 0 && poolInfo.unbond == 0, "pool not empty");
        require(IStakePool(_stakePool).getTotalDelegated() == 0, "delegate not empty");
        require(
            pendingDelegateOf[_stakePool] == 0 &&
                pendingUndelegateOf[_stakePool] == 0 &&
                undistributedRewardOf[_stakePool] == 0,
            "pending not empty"
        );

        bondedPools.remove(_stakePool);
    }

    function addValidator(address _stakePool, address _validator) external onlyAdmin {
        require(allPoolEraStateIs(EraState.OperateAckExecuted, true), "eraState not match");
        validatorsOf[_stakePool].add(_validator);
    }

    function rmValidator(address _stakePool, address _validator) external onlyAdmin {
        require(allPoolEraStateIs(EraState.OperateAckExecuted, true), "eraState not match");
        require(IStakePool(_stakePool).getDelegated(_validator) == 0, "delegate not empty");
        validatorsOf[_stakePool].remove(_validator);
    }

    function redelegate(
        address _stakePool,
        address _srcValidator,
        address _dstValidator,
        uint256 _amount
    ) external onlyAdmin {
        require(allPoolEraStateIs(EraState.OperateAckExecuted, true), "eraState not match");
        require(
            validatorsOf[_stakePool].contains(_srcValidator) && validatorsOf[_stakePool].contains(_dstValidator),
            "val not exist"
        );
        IStakePool(_stakePool).redelegate(_srcValidator, _dstValidator, _amount);
    }

    function setParams(
        uint256 _unstakeFeeCommission,
        uint256 _protocolFeeCommission,
        uint256 _minStakeAmount,
        uint256 _rateChangeLimit,
        uint256 _eraSeconds,
        uint256 _transferGas
    ) external onlyAdmin {
        unstakeFeeCommission = _unstakeFeeCommission;
        protocolFeeCommission = _protocolFeeCommission;
        minStakeAmount = _minStakeAmount;
        rateChangeLimit = _rateChangeLimit;
        eraSeconds = _eraSeconds;
        transferGas = _transferGas;
    }

    function toggleStakeSwitch() external onlyAdmin {
        stakeSwitch = !stakeSwitch;
    }

    function withdrawFee() external onlyAdmin {
        IERC20(rTokenAddress).safeTransferFrom(
            address(this),
            msg.sender,
            IERC20(rTokenAddress).balanceOf(address(this))
        );
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
    ) external onlyVoter {
        bytes32 proposalId = keccak256(
            abi.encodePacked("newEra", _era, _poolAddressList, _undistributedRewardList, _latestRewardTimestampList)
        );
        Proposal memory proposal = _checkProposal(proposalId);

        // Finalize if Threshold has been reached
        if (proposal._yesVotesTotal >= threshold) {
            _exeNewEra(_era, _poolAddressList, _undistributedRewardList, _latestRewardTimestampList);

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
    ) external onlyVoter {
        bytes32 proposalId = keccak256(abi.encodePacked("operate", _era, _poolAddress, _action, _valList, _amountList));
        Proposal memory proposal = _checkProposal(proposalId);

        // Finalize if Threshold has been reached
        if (proposal._yesVotesTotal >= threshold) {
            _exeOperate(_era, _poolAddress, _action, _valList, _amountList);

            proposal._status = ProposalStatus.Executed;
            emit ProposalExecuted(proposalId);
        }

        proposals[proposalId] = proposal;
    }

    function operateAck(uint256 _era, address _poolAddress, uint256[] calldata _successOpIndexList) external onlyVoter {
        bytes32 proposalId = keccak256(abi.encodePacked("operateAck", _era, _poolAddress, _successOpIndexList));
        Proposal memory proposal = _checkProposal(proposalId);

        // Finalize if Threshold has been reached
        if (proposal._yesVotesTotal >= threshold) {
            _exeOperateAck(_era, _poolAddress, _successOpIndexList);

            proposal._status = ProposalStatus.Executed;
            emit ProposalExecuted(proposalId);
        }

        proposals[proposalId] = proposal;
    }

    // ----- staker operation

    function stake(address _stakePoolAddress) external payable {
        require(stakeSwitch, "stake closed");
        require(msg.value >= minStakeAmount, "amount not match");
        require(bondedPools.contains(_stakePoolAddress), "pool not exist");
        (bool success, ) = msg.sender.call{gas: transferGas}("");
        require(success, "staker not payable");

        uint256 rTokenAmount = msg.value.mul(1e18).div(rate);

        // update pool
        PoolInfo storage poolInfo = poolInfoOf[_stakePoolAddress];
        poolInfo.bond = poolInfo.bond.add(msg.value);
        poolInfo.active = poolInfo.active.add(msg.value);

        // transfer token
        (success, ) = _stakePoolAddress.call{value: msg.value}("");
        require(success, "transfer failed");

        // mint rtoken
        totalRTokenSupply = totalRTokenSupply.add(rTokenAmount);
        IERC20MintBurn(rTokenAddress).mint(msg.sender, rTokenAmount);

        emit Stake(msg.sender, _stakePoolAddress, msg.value, rTokenAmount);
    }

    function unstake(uint256 _rTokenAmount, address _stakePoolAddress) external {
        require(stakeSwitch, "stake closed");
        require(_rTokenAmount >= 0, "amount zero");
        require(bondedPools.contains(_stakePoolAddress), "pool not exist");
        (bool success, ) = msg.sender.call{gas: transferGas}("");
        require(success, "unstaker not payable");

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
        IERC20(rTokenAddress).safeTransferFrom(msg.sender, address(this), unstakeFee);

        // unstake info
        unstakeAtIndex[nextUnstakeIndex] = UnstakeInfo({
            era: currentEra,
            pool: _stakePoolAddress,
            receiver: msg.sender,
            amount: tokenAmount
        });
        unstakeOfUser[msg.sender].add(nextUnstakeIndex);

        nextUnstakeIndex = nextUnstakeIndex.add(1);

        emit Unstake(msg.sender, _stakePoolAddress, tokenAmount, _rTokenAmount, leftRTokenAmount);
    }

    function claim(uint256[] calldata _unstakeIndexList) external {
        for (uint256 i = 0; i < _unstakeIndexList.length; ++i) {
            uint256 unstakeIndex = _unstakeIndexList[i];
            UnstakeInfo memory unstakeInfo = unstakeAtIndex[unstakeIndex];

            require(unstakeInfo.era <= currentEra, "not claimable");
            require(unstakeOfUser[unstakeInfo.receiver].remove(unstakeIndex), "already claimed");

            IStakePool(unstakeInfo.pool).claimForStaker(unstakeInfo.receiver, unstakeInfo.amount);
        }
    }

    // ----- helper

    function _checkProposal(bytes32 _proposalId) private view returns (Proposal memory proposal) {
        proposal = proposals[_proposalId];

        require(uint256(proposal._status) <= 1, "proposal already executed");
        require(!_hasVoted(proposal, msg.sender), "already voted");

        if (proposal._status == ProposalStatus.Inactive) {
            proposal = Proposal({_status: ProposalStatus.Active, _yesVotes: 0, _yesVotesTotal: 0});
        }
        proposal._yesVotes = (proposal._yesVotes | subAccountBit(msg.sender)).toUint16();
        proposal._yesVotesTotal++;
    }

    function _exeNewEra(
        uint256 _era,
        address[] calldata _poolAddressList,
        uint256[] calldata _undistributedRewardList,
        uint256[] calldata _latestRewardTimestampList
    ) private {
        require(block.timestamp.div(eraSeconds) >= _era, "calEra not match");
        require(currentEra == 0 || _era == currentEra.add(1), "currentEra not match");
        require(allPoolEraStateIs(EraState.OperateAckExecuted, true), "eraState not match");

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
                ? pendingDelegate.sub(pendingUndelegate)
                : pendingUndelegate.sub(pendingDelegate);

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
            IERC20MintBurn(rTokenAddress).mint(address(this), rTokenProtocolFee);
        }

        // uddate rate
        uint256 newRate = totalNewActive.mul(1e18).div(totalRTokenSupply);
        uint256 rateChange = newRate > rate ? newRate.sub(rate) : rate.sub(newRate);
        require(rateChange.mul(1e18).div(rate) < rateChangeLimit, "rate change over limit");

        // update era
        currentEra = _era;
    }

    function _exeOperate(
        uint256 _era,
        address _poolAddress,
        Action _action,
        address[] calldata _valList,
        uint256[] calldata _amountList
    ) private {
        require(currentEra == _era, "era not match");
        require(poolInfoOf[_poolAddress].eraState == EraState.NewEraExecuted, "eraState not match");
        for (uint256 i = 0; i < _valList.length; ++i) {
            require(_amountList[i] > 0, "amount zero");
            require(validatorsOf[_poolAddress].contains(_valList[i]), "val not exist");
        }

        pendingOperate[_era][_poolAddress] = Operate({action: _action, valList: _valList, amountList: _amountList});

        if (_action == Action.Delegate) {
            IStakePool(_poolAddress).delegate(_valList, _amountList);
        } else if (_action == Action.Undelegate) {
            IStakePool(_poolAddress).undelegate(_valList, _amountList);
        }

        poolInfoOf[_poolAddress].eraState = EraState.OperateExecuted;
    }

    function _exeOperateAck(uint256 _era, address _poolAddress, uint256[] calldata _successOpIndexList) private {
        require(currentEra == _era, "era not match");
        require(poolInfoOf[_poolAddress].eraState == EraState.OperateExecuted, "eraState not match");

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
