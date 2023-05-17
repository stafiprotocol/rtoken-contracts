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
    uint256 public relayerFee; // decimals 18
    uint256 public rateChangeLimit; // decimals 18
    uint256 public transferGas;
    uint256 public eraSeconds;
    uint256 public eraOffset;
    uint256 public unbondingDuration;

    // era state
    uint256 public latestEra; // need migrate
    uint256 private rate; // need migrate decimals 18
    uint256 public totalRTokenSupply; // need migrate
    uint256 public totalProtocolFee; // need migrate

    EnumerableSet.AddressSet bondedPools;
    mapping(address => PoolInfo) public poolInfoOf;
    mapping(address => EnumerableSet.AddressSet) validatorsOf;
    mapping(address => uint256) public latestRewardTimestampOf;
    mapping(address => uint256) public undistributedRewardOf;
    mapping(address => uint256) public pendingDelegateOf;
    mapping(address => uint256) public pendingUndelegateOf;
    mapping(uint256 => mapping(address => Operate)) public pendingOperate; //era=>(pool=>operate)

    // unstake info
    uint256 nextUnstakeIndex;
    mapping(uint256 => UnstakeInfo) unstakeAtIndex;
    mapping(address => EnumerableSet.UintSet) unstakeOfUser;

    // events
    event Stake(address staker, address stakePool, uint256 tokenAmount, uint256 rTokenAmount);
    event Unstake(address staker, address stakePool, uint256 tokenAmount, uint256 rTokenAmount, uint256 burnAmount);
    event ExecuteNewEra(uint256 indexed era, uint256 block);
    event ExecuteOperate(uint256 indexed era, uint256 block);
    event ExecuteOperateAck(uint256 indexed era, uint256 block);

    function init(
        address[] calldata _initialVoters,
        uint256 _initialThreshold,
        address _rTokenAddress,
        uint256 _unbondingDuration
    ) public {
        initMultisig(_initialVoters, _initialThreshold);

        rTokenAddress = _rTokenAddress;
        unbondingDuration = _unbondingDuration;

        minStakeAmount = 1e18;
        rateChangeLimit = 1e15;
        unstakeFeeCommission = 2e15;
        protocolFeeCommission = 1e17;
        relayerFee = 16e15;
        transferGas = 2300;
        eraSeconds = 86400;
        eraOffset = 18033;
    }

    function migrate(
        address _stakePoolAddress,
        address _validator,
        uint256 _bond,
        uint256 _unbond,
        uint256 _active, // delegated + pendingDeleagte + undistributedReward
        uint256 _pendingDelegate,
        uint256 _rate,
        uint256 _totalRTokenSupply,
        uint256 _totalProtocolFee,
        uint256 _era,
        uint256 latestRewardtimestamp,
        uint256 undistributedReward //pending reward + claimable reward
    ) external onlyAdmin {
        require(bondedPools.add(_stakePoolAddress), "already exist");

        validatorsOf[_stakePoolAddress].add(_validator);
        poolInfoOf[_stakePoolAddress] = PoolInfo({
            era: _era,
            eraState: EraState.OperateAckExecuted,
            bond: _bond,
            unbond: _unbond,
            active: _active
        });
        pendingDelegateOf[_stakePoolAddress] = _pendingDelegate;
        rate = _rate;
        totalRTokenSupply = _totalRTokenSupply;
        totalProtocolFee = _totalProtocolFee;
        latestEra = _era;
        latestRewardTimestampOf[_stakePoolAddress] = latestRewardtimestamp;
        undistributedRewardOf[_stakePoolAddress] = undistributedReward;
    }

    // ------ settings

    function addStakePool(address _stakePool) external onlyAdmin {
        require(allPoolEraStateIs(latestEra, EraState.OperateAckExecuted, true), "eraState not match");
        require(bondedPools.add(_stakePool), "pool exist");
    }

    function rmStakePool(address _stakePool) external onlyAdmin {
        PoolInfo memory poolInfo = poolInfoOf[_stakePool];
        require(allPoolEraStateIs(latestEra, EraState.OperateAckExecuted, true), "eraState not match");
        require(poolInfo.active == 0 && poolInfo.bond == 0 && poolInfo.unbond == 0, "pool not empty");
        require(IStakePool(_stakePool).getTotalDelegated() == 0, "delegate not empty");
        require(
            pendingDelegateOf[_stakePool] == 0 &&
                pendingUndelegateOf[_stakePool] == 0 &&
                undistributedRewardOf[_stakePool] == 0,
            "pending not empty"
        );

        require(bondedPools.remove(_stakePool), "pool not exist");
    }

    function addValidator(address _stakePool, address _validator) external onlyAdmin {
        require(allPoolEraStateIs(latestEra, EraState.OperateAckExecuted, true), "eraState not match");
        validatorsOf[_stakePool].add(_validator);
    }

    function rmValidator(address _stakePool, address _validator) external onlyAdmin {
        require(allPoolEraStateIs(latestEra, EraState.OperateAckExecuted, true), "eraState not match");
        require(IStakePool(_stakePool).getDelegated(_validator) == 0, "delegate not empty");
        validatorsOf[_stakePool].remove(_validator);
    }

    function redelegate(
        address _stakePool,
        address _srcValidator,
        address _dstValidator,
        uint256 _amount
    ) external onlyAdmin {
        require(allPoolEraStateIs(latestEra, EraState.OperateAckExecuted, true), "eraState not match");
        require(
            validatorsOf[_stakePool].contains(_srcValidator) && validatorsOf[_stakePool].contains(_dstValidator),
            "val not exist"
        );
        IStakePool(_stakePool).redelegate(_srcValidator, _dstValidator, _amount);
    }

    function setParams(
        uint256 _unstakeFeeCommission,
        uint256 _protocolFeeCommission,
        uint256 _relayerFee,
        uint256 _minStakeAmount,
        uint256 _unbondingDuration,
        uint256 _rateChangeLimit,
        uint256 _eraSeconds,
        uint256 _eraOffset,
        uint256 _transferGas
    ) external onlyAdmin {
        unstakeFeeCommission = _unstakeFeeCommission == 1 ? unstakeFeeCommission : _unstakeFeeCommission;
        protocolFeeCommission = _protocolFeeCommission == 1 ? protocolFeeCommission : _protocolFeeCommission;
        relayerFee = _relayerFee == 1 ? relayerFee : _relayerFee;
        minStakeAmount = _minStakeAmount == 0 ? minStakeAmount : _minStakeAmount;
        unbondingDuration = _unbondingDuration == 0 ? unbondingDuration : _unbondingDuration;
        rateChangeLimit = _rateChangeLimit == 0 ? rateChangeLimit : _rateChangeLimit;
        eraSeconds = _eraSeconds == 0 ? eraSeconds : _eraSeconds;
        eraOffset = _eraOffset == 0 ? eraOffset : _eraOffset;
        transferGas = _transferGas == 0 ? transferGas : _transferGas;
    }

    function toggleStakeSwitch() external onlyAdmin {
        stakeSwitch = !stakeSwitch;
    }

    function withdrawProtocolFee(address _to) external onlyAdmin {
        IERC20(rTokenAddress).safeTransfer(_to, IERC20(rTokenAddress).balanceOf(address(this)));
    }

    function withdrawRelayerFee(address _to) external onlyAdmin {
        (bool success, ) = _to.call{value: address(this).balance}("");
        require(success, "failed to withdraw");
    }

    // ----- getters

    function getRate() external view override returns (uint256) {
        return rate;
    }

    function getStakeRelayerFee() public view returns (uint256) {
        return relayerFee.div(2);
    }

    function getUnstakeRelayerFee() public view returns (uint256) {
        return relayerFee;
    }

    function allPoolEraStateIs(uint256 _era, EraState _eraState, bool _skipUninitialized) public view returns (bool) {
        uint256 poolLength = bondedPools.length();
        for (uint256 i = 0; i < poolLength; ++i) {
            PoolInfo memory poolInfo = poolInfoOf[bondedPools.at(i)];
            if (_skipUninitialized && poolInfo.eraState == EraState.Uninitialized) {
                continue;
            }
            if (poolInfo.era != _era || poolInfo.eraState != _eraState) {
                return false;
            }
        }
        return true;
    }

    function getBondedPools() external view returns (address[] memory pools) {
        pools = new address[](bondedPools.length());
        for (uint256 i = 0; i < bondedPools.length(); ++i) {
            pools[i] = bondedPools.at(i);
        }
        return pools;
    }

    function getValidatorsOf(address _poolAddress) external view returns (address[] memory validators) {
        validators = new address[](validatorsOf[_poolAddress].length());
        for (uint256 i = 0; i < validatorsOf[_poolAddress].length(); ++i) {
            validators[i] = validatorsOf[_poolAddress].at(i);
        }
        return validators;
    }

    function getUnstakeIndexListOf(address _staker) external view returns (uint256[] memory unstakeIndexList) {
        unstakeIndexList = new uint256[](unstakeOfUser[_staker].length());
        for (uint256 i = 0; i < unstakeOfUser[_staker].length(); ++i) {
            unstakeIndexList[i] = unstakeOfUser[_staker].at(i);
        }
        return unstakeIndexList;
    }

    function currentEra() public view returns (uint256) {
        return block.timestamp.div(eraSeconds).sub(eraOffset);
    }

    // ----- vote

    function newEra(
        uint256 _era,
        address[] calldata _poolAddressList,
        uint256[] calldata _newRewardList,
        uint256[] calldata _latestRewardTimestampList
    ) external onlyVoter {
        bytes32 proposalId = keccak256(
            abi.encodePacked("newEra", _era, _poolAddressList, _newRewardList, _latestRewardTimestampList)
        );
        Proposal memory proposal = _checkProposal(proposalId);

        // Finalize if Threshold has been reached
        if (proposal._yesVotesTotal >= threshold) {
            _executeNewEra(_era, _poolAddressList, _newRewardList, _latestRewardTimestampList);

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
            _executeOperate(_era, _poolAddress, _action, _valList, _amountList);

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
            _executeOperateAck(_era, _poolAddress, _successOpIndexList);

            proposal._status = ProposalStatus.Executed;
            emit ProposalExecuted(proposalId);
        }

        proposals[proposalId] = proposal;
    }

    // ----- staker operation

    function stake(uint256 _stakeAmount) external payable {
        stakeWithPool(bondedPools.at(0), _stakeAmount);
    }

    function unstake(uint256 _rTokenAmount) external payable {
        unstakeWithPool(bondedPools.at(0), _rTokenAmount);
    }

    function withdraw() external {
        withdrawWithPool(bondedPools.at(0));
    }

    function stakeWithPool(address _stakePoolAddress, uint256 _stakeAmount) public payable {
        require(stakeSwitch, "stake closed");
        require(msg.value >= _stakeAmount.add(getStakeRelayerFee()), "fee not enough");
        require(_stakeAmount >= minStakeAmount, "amount not enough");
        require(bondedPools.contains(_stakePoolAddress), "pool not exist");
        (bool success, ) = msg.sender.call{gas: transferGas}("");
        require(success, "staker not payable");

        uint256 rTokenAmount = _stakeAmount.mul(1e18).div(rate);

        // update pool
        PoolInfo storage poolInfo = poolInfoOf[_stakePoolAddress];
        poolInfo.bond = poolInfo.bond.add(_stakeAmount);
        poolInfo.active = poolInfo.active.add(_stakeAmount);

        // transfer token
        (success, ) = _stakePoolAddress.call{value: _stakeAmount}("");
        require(success, "transfer failed");

        // mint rtoken
        totalRTokenSupply = totalRTokenSupply.add(rTokenAmount);
        IERC20MintBurn(rTokenAddress).mint(msg.sender, rTokenAmount);

        emit Stake(msg.sender, _stakePoolAddress, _stakeAmount, rTokenAmount);
    }

    function unstakeWithPool(address _stakePoolAddress, uint256 _rTokenAmount) public payable {
        require(stakeSwitch, "stake closed");
        require(_rTokenAmount > 0, "rtoken amount zero");
        require(msg.value >= getUnstakeRelayerFee(), "fee not enough");
        require(bondedPools.contains(_stakePoolAddress), "pool not exist");
        (bool success, ) = msg.sender.call{gas: transferGas}("");
        require(success, "unstaker not payable");
        require(unstakeOfUser[msg.sender].length() <= 100, "unstake number limit"); //todo test max limit number

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

        // protocol fee
        totalProtocolFee = totalProtocolFee.add(unstakeFee);
        IERC20(rTokenAddress).safeTransferFrom(msg.sender, address(this), unstakeFee);

        // unstake info
        unstakeAtIndex[nextUnstakeIndex] = UnstakeInfo({
            era: latestEra,
            pool: _stakePoolAddress,
            receiver: msg.sender,
            amount: tokenAmount
        });
        unstakeOfUser[msg.sender].add(nextUnstakeIndex);

        nextUnstakeIndex = nextUnstakeIndex.add(1);

        emit Unstake(msg.sender, _stakePoolAddress, tokenAmount, _rTokenAmount, leftRTokenAmount);
    }

    function withdrawWithPool(address _poolAddress) public {
        uint256 totalWithdrawAmount;
        uint256 length = unstakeOfUser[msg.sender].length();
        uint256[] memory unstakeIndexList = new uint256[](length);

        for (uint256 i = 0; i < length; ++i) {
            unstakeIndexList[i] = unstakeOfUser[msg.sender].at(i);
        }

        for (uint256 i = 0; i < length; ++i) {
            uint256 unstakeIndex = unstakeIndexList[i];
            UnstakeInfo memory unstakeInfo = unstakeAtIndex[unstakeIndex];
            if (unstakeInfo.era.add(unbondingDuration) > latestEra) {
                continue;
            }

            require(unstakeInfo.pool == _poolAddress, "pool not match");
            require(unstakeOfUser[msg.sender].remove(unstakeIndex), "already withdrawed");

            totalWithdrawAmount = totalWithdrawAmount.add(unstakeInfo.amount);
        }

        if (totalWithdrawAmount > 0) {
            IStakePool(_poolAddress).withdrawForStaker(msg.sender, totalWithdrawAmount);
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
        proposal._yesVotes = (proposal._yesVotes | voterBit(msg.sender)).toUint16();
        proposal._yesVotesTotal++;
    }

    function _executeNewEra(
        uint256 _era,
        address[] calldata _poolAddressList,
        uint256[] calldata _newRewardList,
        uint256[] calldata _latestRewardTimestampList
    ) private {
        require(currentEra() >= _era, "calEra not match");
        require(_era == latestEra.add(1), "latestEra not match");
        require(allPoolEraStateIs(latestEra, EraState.OperateAckExecuted, true), "eraState not match");
        require(
            _poolAddressList.length == bondedPools.length() &&
                _poolAddressList.length == _newRewardList.length &&
                _poolAddressList.length == _latestRewardTimestampList.length,
            "length not match"
        );
        // update era
        latestEra = _era;

        // update pool info
        uint256 totalNewReward;
        uint256 totalNewActive;
        uint256 minDelegation = IStakePool(bondedPools.at(0)).getMinDelegation();
        for (uint256 i = 0; i < _poolAddressList.length; ++i) {
            address poolAddress = _poolAddressList[i];
            require(
                _latestRewardTimestampList[i] >= latestRewardTimestampOf[poolAddress] &&
                    _latestRewardTimestampList[i] < block.timestamp,
                "timestamp not match"
            );

            // update latest reward timestamp
            latestRewardTimestampOf[poolAddress] = _latestRewardTimestampList[i];

            if (_newRewardList[i] > 0) {
                // update undistributedReward
                undistributedRewardOf[poolAddress] = undistributedRewardOf[poolAddress].add(_newRewardList[i]);
                // total new reward
                totalNewReward = totalNewReward.add(_newRewardList[i]);
            }

            PoolInfo memory poolInfo = poolInfoOf[poolAddress];
            require(poolInfo.era != latestEra, "duplicate pool");
            require(bondedPools.contains(poolAddress), "pool not exist");

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

            totalNewActive = totalNewActive.add(poolNewActive);

            // update pool state
            poolInfo.era = latestEra;
            poolInfo.active = poolNewActive;

            if (pendingUndelegateOf[poolAddress] == 0 && pendingDelegateOf[poolAddress] < minDelegation) {
                poolInfo.eraState = EraState.OperateAckExecuted;
            } else {
                poolInfo.eraState = EraState.NewEraExecuted;
            }

            poolInfoOf[poolAddress] = poolInfo;
        }

        // cal protocol fee
        if (totalNewReward > 0) {
            uint256 rTokenProtocolFee = totalNewReward.mul(protocolFeeCommission).div(rate);
            totalProtocolFee = totalProtocolFee.add(rTokenProtocolFee);

            // mint rtoken
            totalRTokenSupply = totalRTokenSupply.add(rTokenProtocolFee);
            IERC20MintBurn(rTokenAddress).mint(address(this), rTokenProtocolFee);
        }

        // uddate rate
        uint256 newRate = totalNewActive.mul(1e18).div(totalRTokenSupply);
        uint256 rateChange = newRate > rate ? newRate.sub(rate) : rate.sub(newRate);
        require(rateChange.mul(1e18).div(rate) < rateChangeLimit, "rate change over limit");

        emit ExecuteNewEra(_era, block.number);
    }

    function _executeOperate(
        uint256 _era,
        address _poolAddress,
        Action _action,
        address[] calldata _valList,
        uint256[] calldata _amountList
    ) private {
        require(latestEra == _era, "era not match");
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

        emit ExecuteOperate(_era, block.number);
    }

    function _executeOperateAck(uint256 _era, address _poolAddress, uint256[] calldata _successOpIndexList) private {
        require(latestEra == _era, "era not match");
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

        emit ExecuteOperateAck(_era, block.number);
    }
}
