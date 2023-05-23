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

    address public rTokenAddress;
    uint256 public minStakeAmount;
    uint256 public unstakeFeeCommission; // decimals 18
    uint256 public protocolFeeCommission; // decimals 18
    uint256 public rateChangeLimit; // decimals 18
    uint256 public transferGas;
    uint256 public eraSeconds;
    uint256 public eraOffset;
    uint256 public unbondingDuration;
    uint256 public delegatedDiffLimit;

    uint256 public latestEra;
    uint256 private rate; // decimals 18
    uint256 public totalRTokenSupply;
    uint256 public totalProtocolFee;

    EnumerableSet.AddressSet bondedPools;
    mapping(address => PoolInfo) public poolInfoOf;
    mapping(address => EnumerableSet.AddressSet) validatorsOf;
    mapping(address => uint256) public latestRewardTimestampOf;
    mapping(address => uint256) public undistributedRewardOf;
    mapping(address => uint256) public pendingDelegateOf;
    mapping(address => uint256) public pendingUndelegateOf;
    mapping(address => mapping(address => uint256)) public delegatedOfValidator; // delegator => validator => amount
    mapping(uint256 => uint256) public eraRate;

    // unstake info
    uint256 public nextUnstakeIndex;
    mapping(uint256 => UnstakeInfo) public unstakeAtIndex;
    mapping(address => EnumerableSet.UintSet) unstakeOfUser;

    // events
    event Stake(address staker, address poolAddress, uint256 tokenAmount, uint256 rTokenAmount);
    event Unstake(
        address staker,
        address poolAddress,
        uint256 tokenAmount,
        uint256 rTokenAmount,
        uint256 burnAmount,
        uint256 unstakeIndex
    );
    event Withdraw(address staker, address poolAddress, uint256 tokenAmount, uint256[] unstakeIndexList);
    event ExecuteNewEra(uint256 indexed era, uint256 rate);
    event Settle(uint256 indexed era, address indexed pool);
    event RepairDelegated(address pool, address validator, uint256 govDelegated, uint256 localDelegated);
    event SetUnbondingDuration(uint256 bondingDuration);

    // init
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
        transferGas = 2300;
        eraSeconds = 86400;
        eraOffset = 18033;
        delegatedDiffLimit = 1e11;
    }

    // ----- getters

    function getRate() external view override returns (uint256) {
        return rate;
    }

    function getStakeRelayerFee() public view returns (uint256) {
        return IStakePool(bondedPools.at(0)).getRelayerFee().div(2);
    }

    function getUnstakeRelayerFee() public view returns (uint256) {
        return IStakePool(bondedPools.at(0)).getRelayerFee();
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

    // ------ settings

    function migrate(
        address _poolAddress,
        address _validator,
        uint256 _govDelegated,
        uint256 _bond,
        uint256 _unbond,
        uint256 _pendingDelegate,
        uint256 _rate,
        uint256 _totalRTokenSupply,
        uint256 _totalProtocolFee,
        uint256 _era,
        uint256 _latestRewardtimestamp,
        uint256 _undistributedReward //pending reward + claimable reward
    ) external onlyAdmin {
        require(rate == 0, "already migrate");
        require(bondedPools.add(_poolAddress), "already exist");

        validatorsOf[_poolAddress].add(_validator);
        delegatedOfValidator[_poolAddress][_validator] = _govDelegated;
        poolInfoOf[_poolAddress] = PoolInfo({
            era: _era,
            bond: _bond,
            unbond: _unbond,
            active: _govDelegated.add(_pendingDelegate).add(_undistributedReward)
        });
        pendingDelegateOf[_poolAddress] = _pendingDelegate;
        rate = _rate;
        totalRTokenSupply = _totalRTokenSupply;
        totalProtocolFee = _totalProtocolFee;
        latestEra = _era;
        eraRate[_era] = _rate;
        latestRewardTimestampOf[_poolAddress] = _latestRewardtimestamp;
        undistributedRewardOf[_poolAddress] = _undistributedReward;
    }

    function setParams(
        uint256 _unstakeFeeCommission,
        uint256 _protocolFeeCommission,
        uint256 _minStakeAmount,
        uint256 _unbondingDuration,
        uint256 _rateChangeLimit,
        uint256 _eraSeconds,
        uint256 _eraOffset,
        uint256 _transferGas,
        uint256 _delegatedDiffLimit
    ) external onlyAdmin {
        unstakeFeeCommission = _unstakeFeeCommission == 1 ? unstakeFeeCommission : _unstakeFeeCommission;
        protocolFeeCommission = _protocolFeeCommission == 1 ? protocolFeeCommission : _protocolFeeCommission;
        minStakeAmount = _minStakeAmount == 0 ? minStakeAmount : _minStakeAmount;
        rateChangeLimit = _rateChangeLimit == 0 ? rateChangeLimit : _rateChangeLimit;
        eraSeconds = _eraSeconds == 0 ? eraSeconds : _eraSeconds;
        eraOffset = _eraOffset == 0 ? eraOffset : _eraOffset;
        transferGas = _transferGas == 0 ? transferGas : _transferGas;
        delegatedDiffLimit = _delegatedDiffLimit == 0 ? delegatedDiffLimit : _delegatedDiffLimit;

        if (_unbondingDuration > 0) {
            unbondingDuration = _unbondingDuration;
            emit SetUnbondingDuration(_unbondingDuration);
        }
    }

    function addStakePool(address _poolAddress) external onlyAdmin {
        require(bondedPools.add(_poolAddress), "pool exist");
    }

    function rmStakePool(address _poolAddress) external onlyAdmin {
        PoolInfo memory poolInfo = poolInfoOf[_poolAddress];
        require(poolInfo.active == 0 && poolInfo.bond == 0 && poolInfo.unbond == 0, "pool not empty");
        require(IStakePool(_poolAddress).getTotalDelegated() == 0, "delegate not empty");
        require(
            pendingDelegateOf[_poolAddress] == 0 &&
                pendingUndelegateOf[_poolAddress] == 0 &&
                undistributedRewardOf[_poolAddress] == 0,
            "pending not empty"
        );

        require(bondedPools.remove(_poolAddress), "pool not exist");
    }

    function rmValidator(address _poolAddress, address _validator) external onlyAdmin {
        require(IStakePool(_poolAddress).getDelegated(_validator) == 0, "delegate not empty");

        validatorsOf[_poolAddress].remove(_validator);
        delegatedOfValidator[_poolAddress][_validator] = 0;
    }

    function redelegate(
        address _poolAddress,
        address _srcValidator,
        address _dstValidator,
        uint256 _amount
    ) external onlyAdmin {
        require(validatorsOf[_poolAddress].contains(_srcValidator), "val not exist");

        if (!validatorsOf[_poolAddress].contains(_dstValidator)) {
            validatorsOf[_poolAddress].add(_dstValidator);
        }

        require(
            block.timestamp >= IStakePool(_poolAddress).getPendingRedelegateTime(_srcValidator, _dstValidator) &&
                block.timestamp >= IStakePool(_poolAddress).getPendingRedelegateTime(_dstValidator, _srcValidator),
            "pending redelegation exist"
        );

        _checkAndRepairDelegated(_poolAddress);

        delegatedOfValidator[_poolAddress][_srcValidator] = delegatedOfValidator[_poolAddress][_srcValidator].sub(
            _amount
        );
        delegatedOfValidator[_poolAddress][_dstValidator] = delegatedOfValidator[_poolAddress][_dstValidator].add(
            _amount
        );

        IStakePool(_poolAddress).redelegate(_srcValidator, _dstValidator, _amount);
    }

    function withdrawProtocolFee(address _to) external onlyAdmin {
        IERC20(rTokenAddress).safeTransfer(_to, IERC20(rTokenAddress).balanceOf(address(this)));
    }

    function withdrawRelayerFee(address _to) external onlyAdmin {
        (bool success, ) = _to.call{value: address(this).balance}("");
        require(success, "failed to withdraw");
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

    function stakeWithPool(address _poolAddress, uint256 _stakeAmount) public payable {
        require(msg.value >= _stakeAmount.add(getStakeRelayerFee()), "fee not enough");
        require(_stakeAmount >= minStakeAmount, "amount not enough");
        require(bondedPools.contains(_poolAddress), "pool not exist");
        (bool success, ) = msg.sender.call{gas: transferGas}("");
        require(success, "staker not payable");

        uint256 rTokenAmount = _stakeAmount.mul(1e18).div(rate);

        // update pool
        PoolInfo storage poolInfo = poolInfoOf[_poolAddress];
        poolInfo.bond = poolInfo.bond.add(_stakeAmount);
        poolInfo.active = poolInfo.active.add(_stakeAmount);

        // transfer token
        (success, ) = _poolAddress.call{value: _stakeAmount}("");
        require(success, "transfer failed");

        // mint rtoken
        totalRTokenSupply = totalRTokenSupply.add(rTokenAmount);
        IERC20MintBurn(rTokenAddress).mint(msg.sender, rTokenAmount);

        emit Stake(msg.sender, _poolAddress, _stakeAmount, rTokenAmount);
    }

    function unstakeWithPool(address _poolAddress, uint256 _rTokenAmount) public payable {
        require(_rTokenAmount > 0, "rtoken amount zero");
        require(msg.value >= getUnstakeRelayerFee(), "fee not enough");
        require(bondedPools.contains(_poolAddress), "pool not exist");
        (bool success, ) = msg.sender.call{gas: transferGas}("");
        require(success, "unstaker not payable");
        require(unstakeOfUser[msg.sender].length() <= 100, "unstake number limit"); //todo test max limit number

        uint256 unstakeFee = _rTokenAmount.mul(unstakeFeeCommission).div(1e18);
        uint256 leftRTokenAmount = _rTokenAmount.sub(unstakeFee);
        uint256 tokenAmount = leftRTokenAmount.mul(rate).div(1e18);

        // update pool
        PoolInfo storage poolInfo = poolInfoOf[_poolAddress];
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
            era: currentEra(),
            pool: _poolAddress,
            receiver: msg.sender,
            amount: tokenAmount
        });
        unstakeOfUser[msg.sender].add(nextUnstakeIndex);

        emit Unstake(msg.sender, _poolAddress, tokenAmount, _rTokenAmount, leftRTokenAmount, nextUnstakeIndex);

        nextUnstakeIndex = nextUnstakeIndex.add(1);
    }

    function withdrawWithPool(address _poolAddress) public {
        uint256 totalWithdrawAmount;
        uint256 length = unstakeOfUser[msg.sender].length();
        uint256[] memory unstakeIndexList = new uint256[](length);

        for (uint256 i = 0; i < length; ++i) {
            unstakeIndexList[i] = unstakeOfUser[msg.sender].at(i);
        }
        uint256 curEra = currentEra();
        for (uint256 i = 0; i < length; ++i) {
            uint256 unstakeIndex = unstakeIndexList[i];
            UnstakeInfo memory unstakeInfo = unstakeAtIndex[unstakeIndex];
            if (unstakeInfo.era.add(unbondingDuration) > curEra || unstakeInfo.pool != _poolAddress) {
                continue;
            }

            require(unstakeOfUser[msg.sender].remove(unstakeIndex), "already withdrawed");

            totalWithdrawAmount = totalWithdrawAmount.add(unstakeInfo.amount);
        }

        if (totalWithdrawAmount > 0) {
            IStakePool(_poolAddress).withdrawForStaker(msg.sender, totalWithdrawAmount);
        }

        emit Withdraw(msg.sender, _poolAddress, totalWithdrawAmount, unstakeIndexList);
    }

    // ----- permissionless

    function settle(address _poolAddress) public {
        require(bondedPools.contains(_poolAddress), "pool not exist");
        _checkAndRepairDelegated(_poolAddress);

        // claim undelegated
        IStakePool(_poolAddress).checkAndClaimUndelegated();

        PoolInfo memory poolInfo = poolInfoOf[_poolAddress];

        // cal pending value
        uint256 pendingDelegate = pendingDelegateOf[_poolAddress].add(poolInfo.bond);
        uint256 pendingUndelegate = pendingUndelegateOf[_poolAddress].add(poolInfo.unbond);

        uint256 deduction = pendingDelegate > pendingUndelegate ? pendingUndelegate : pendingDelegate;
        pendingDelegate = pendingDelegate.sub(deduction);
        pendingUndelegate = pendingUndelegate.sub(deduction);

        // update pool state
        poolInfo.bond = 0;
        poolInfo.unbond = 0;
        poolInfoOf[_poolAddress] = poolInfo;

        _settle(_poolAddress, pendingDelegate, pendingUndelegate);
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

    function _checkAndRepairDelegated(address _poolAddress) private {
        uint256[3] memory requestInFly = IStakePool(_poolAddress).getRequestInFly();
        require(requestInFly[0] == 0 && requestInFly[1] == 0 && requestInFly[2] == 0, "request in fly");

        uint256 valLength = validatorsOf[_poolAddress].length();
        for (uint256 i = 0; i < valLength; ++i) {
            address val = validatorsOf[_poolAddress].at(i);
            uint256 govDelegated = IStakePool(_poolAddress).getDelegated(val);
            uint256 localDelegated = delegatedOfValidator[_poolAddress][val];

            uint256 diff;
            if (govDelegated > localDelegated.add(delegatedDiffLimit)) {
                diff = govDelegated.sub(localDelegated);

                pendingUndelegateOf[_poolAddress] = pendingUndelegateOf[_poolAddress].add(diff);
            } else if (localDelegated > govDelegated.add(delegatedDiffLimit)) {
                diff = localDelegated.sub(govDelegated);

                pendingDelegateOf[_poolAddress] = pendingDelegateOf[_poolAddress].add(diff);
            }

            delegatedOfValidator[_poolAddress][val] = govDelegated;
            emit RepairDelegated(_poolAddress, val, govDelegated, localDelegated);
        }
    }

    function _executeNewEra(
        uint256 _era,
        address[] calldata _poolAddressList,
        uint256[] calldata _newRewardList,
        uint256[] calldata _latestRewardTimestampList
    ) private {
        require(currentEra() >= _era, "calEra not match");
        require(_era == latestEra.add(1), "latestEra not match");
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
        for (uint256 i = 0; i < _poolAddressList.length; ++i) {
            address poolAddress = _poolAddressList[i];
            require(
                _latestRewardTimestampList[i] >= latestRewardTimestampOf[poolAddress] &&
                    _latestRewardTimestampList[i] < block.timestamp,
                "timestamp not match"
            );
            PoolInfo memory poolInfo = poolInfoOf[poolAddress];
            require(poolInfo.era != latestEra, "duplicate pool");
            require(bondedPools.contains(poolAddress), "pool not exist");

            _checkAndRepairDelegated(poolAddress);

            // update latest reward timestamp
            latestRewardTimestampOf[poolAddress] = _latestRewardTimestampList[i];

            if (_newRewardList[i] > 0) {
                // update undistributedReward
                undistributedRewardOf[poolAddress] = undistributedRewardOf[poolAddress].add(_newRewardList[i]);
                // total new reward
                totalNewReward = totalNewReward.add(_newRewardList[i]);
            }

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

            uint256 deduction = pendingDelegate > pendingUndelegate ? pendingUndelegate : pendingDelegate;
            pendingDelegate = pendingDelegate.sub(deduction);
            pendingUndelegate = pendingUndelegate.sub(deduction);

            // cal total active
            uint256 poolNewActive = IStakePool(poolAddress)
                .getTotalDelegated()
                .add(pendingDelegate)
                .add(undistributedRewardOf[poolAddress])
                .sub(pendingUndelegate);

            totalNewActive = totalNewActive.add(poolNewActive);

            // update pool state
            poolInfo.era = latestEra;
            poolInfo.active = poolNewActive;
            poolInfo.bond = 0;
            poolInfo.unbond = 0;

            poolInfoOf[poolAddress] = poolInfo;

            // settle
            _settle(poolAddress, pendingDelegate, pendingUndelegate);
        }

        // cal protocol fee
        if (totalNewReward > 0) {
            uint256 rTokenProtocolFee = totalNewReward.mul(protocolFeeCommission).div(rate);
            totalProtocolFee = totalProtocolFee.add(rTokenProtocolFee);

            // mint rtoken
            totalRTokenSupply = totalRTokenSupply.add(rTokenProtocolFee);
            IERC20MintBurn(rTokenAddress).mint(address(this), rTokenProtocolFee);
        }

        // update rate
        uint256 newRate = totalNewActive.mul(1e18).div(totalRTokenSupply);
        uint256 rateChange = newRate > rate ? newRate.sub(rate) : rate.sub(newRate);
        require(rateChange.mul(1e18).div(rate) < rateChangeLimit, "rate change over limit");

        rate = newRate;
        eraRate[_era] = newRate;

        emit ExecuteNewEra(_era, newRate);
    }

    // maybe call delegate/undelegate to stakepool and update pending value
    function _settle(address _poolAddress, uint256 pendingDelegate, uint256 pendingUndelegate) private {
        // delegate and cal pending value
        uint256 minDelegation = IStakePool(_poolAddress).getMinDelegation();
        if (pendingDelegate >= minDelegation) {
            address val = validatorsOf[_poolAddress].at(0);

            delegatedOfValidator[_poolAddress][val] = delegatedOfValidator[_poolAddress][val].add(pendingDelegate);
            IStakePool(_poolAddress).delegate(val, pendingDelegate);

            pendingDelegate = 0;
        }

        // undelegate and cal pending value
        if (pendingUndelegate > 0) {
            uint256 needUndelegate = pendingUndelegate;
            uint256 realUndelegate = 0;

            for (uint256 i = 0; i < validatorsOf[_poolAddress].length(); ++i) {
                if (needUndelegate == 0) {
                    break;
                }
                address val = validatorsOf[_poolAddress].at(i);

                if (block.timestamp < IStakePool(_poolAddress).getPendingUndelegateTime(val)) {
                    continue;
                }

                uint256 govDelegated = IStakePool(_poolAddress).getDelegated(val);
                if (needUndelegate < govDelegated) {
                    uint256 willUndelegate = needUndelegate;
                    if (willUndelegate < minDelegation) {
                        willUndelegate = minDelegation;
                        if (willUndelegate > govDelegated) {
                            willUndelegate = govDelegated;
                        }
                    }

                    delegatedOfValidator[_poolAddress][val] = delegatedOfValidator[_poolAddress][val].sub(
                        willUndelegate
                    );
                    IStakePool(_poolAddress).undelegate(val, willUndelegate);

                    needUndelegate = 0;
                    realUndelegate = realUndelegate.add(willUndelegate);
                } else {
                    delegatedOfValidator[_poolAddress][val] = delegatedOfValidator[_poolAddress][val].sub(govDelegated);
                    IStakePool(_poolAddress).undelegate(val, govDelegated);

                    needUndelegate = needUndelegate.sub(govDelegated);
                    realUndelegate = realUndelegate.add(govDelegated);
                }
            }

            if (realUndelegate > pendingUndelegate) {
                pendingDelegate = pendingDelegate.add(realUndelegate.sub(pendingUndelegate));
                pendingUndelegate = 0;
            } else {
                pendingUndelegate = pendingUndelegate.sub(realUndelegate);
            }
        }

        // update pending value
        pendingDelegateOf[_poolAddress] = pendingDelegate;
        pendingUndelegateOf[_poolAddress] = pendingUndelegate;

        emit Settle(currentEra(), _poolAddress);
    }
}
