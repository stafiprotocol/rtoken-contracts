pragma solidity 0.7.6;
// SPDX-License-Identifier: GPL-3.0-only

import {SafeERC20, IERC20, SafeMath} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../balancer-metastable-rate-providers/interfaces/IRateProvider.sol";
import "./Types.sol";
import "./IStakePool.sol";
import "./IGovStakeManager.sol";
import "./IERC20MintBurn.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/EnumerableSet.sol";

contract StakeManager is IRateProvider {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    address public admin;
    address public delegationBalancer;
    address public rTokenAddress;
    address public erc20TokenAddress;
    address public govStakeManagerAddress;
    uint256 public minStakeAmount;
    uint256 public unstakeFeeCommission; // decimals 18
    uint256 public protocolFeeCommission; // decimals 18
    uint256 public rateChangeLimit; // decimals 18
    uint256 public eraSeconds;
    uint256 public eraOffset;

    uint256 public latestEra;
    uint256 private rate; // decimals 18
    uint256 public totalRTokenSupply;
    uint256 public totalProtocolFee;

    EnumerableSet.AddressSet bondedPools;
    mapping(address => EnumerableSet.UintSet) validatorIdsOf; // pool => validatorIds
    mapping(uint256 => uint256) public eraRate; // era => rate
    mapping(address => uint256) public undelegateRewardOf; // pool => undelegate reward

    // unstake info
    uint256 public nextUnstakeIndex;
    mapping(uint256 => UnstakeInfo) public unstakeAtIndex;
    mapping(address => EnumerableSet.UintSet) unstakesOfUser;

    // events
    event Stake(address staker, address poolAddress, uint256 validator, uint256 tokenAmount, uint256 rTokenAmount);
    event Unstake(
        address staker,
        address poolAddress,
        int256[] validator,
        uint256 tokenAmount,
        uint256 rTokenAmount,
        uint256 burnAmount,
        int256[] unstakeIndexList
    );
    event Withdraw(address staker, address poolAddress, uint256 tokenAmount, int256[] unstakeIndexList);
    event ExecuteNewEra(uint256 indexed era, uint256 rate);
    event DelegateReward(address pool, uint256 validator, uint256 amount);

    // init
    function init(address _rTokenAddress, address _erc20TokenAddress, address _govStakeManagerAddress) public {
        require(admin == address(0), "already init");

        admin = msg.sender;
        delegationBalancer = msg.sender;
        rTokenAddress = _rTokenAddress;
        erc20TokenAddress = _erc20TokenAddress;
        govStakeManagerAddress = _govStakeManagerAddress;

        minStakeAmount = 1e12;
        rateChangeLimit = 1e15;
        unstakeFeeCommission = 2e15;
        protocolFeeCommission = 1e17;
        eraSeconds = 86400;
        eraOffset = 16845;
    }

    // modifer
    modifier onlyAdmin() {
        require(admin == msg.sender, "caller is not admin");
        _;
    }

    modifier onlyDelegationBalancer() {
        require(delegationBalancer == msg.sender, "caller is not delegation balancer");
        _;
    }

    // ----- getters

    function getRate() external view override returns (uint256) {
        return rate;
    }

    function getBondedPools() public view returns (address[] memory pools) {
        pools = new address[](bondedPools.length());
        for (uint256 i = 0; i < bondedPools.length(); ++i) {
            pools[i] = bondedPools.at(i);
        }
        return pools;
    }

    function getValidatorIdsOf(address _poolAddress) public view returns (uint256[] memory validatorIds) {
        validatorIds = new uint256[](validatorIdsOf[_poolAddress].length());
        for (uint256 i = 0; i < validatorIdsOf[_poolAddress].length(); ++i) {
            validatorIds[i] = validatorIdsOf[_poolAddress].at(i);
        }
        return validatorIds;
    }

    function getUnstakeIndexListOf(address _staker) external view returns (uint256[] memory unstakeIndexList) {
        unstakeIndexList = new uint256[](unstakesOfUser[_staker].length());
        for (uint256 i = 0; i < unstakesOfUser[_staker].length(); ++i) {
            unstakeIndexList[i] = unstakesOfUser[_staker].at(i);
        }
        return unstakeIndexList;
    }

    function currentEra() public view returns (uint256) {
        return block.timestamp.div(eraSeconds).sub(eraOffset);
    }

    // ------ settings

    function migrate(
        address _poolAddress,
        uint256 _validatorId,
        uint256 _rate,
        uint256 _totalRTokenSupply,
        uint256 _totalProtocolFee,
        uint256 _era
    ) external onlyAdmin {
        require(rate == 0, "already migrate");
        require(bondedPools.add(_poolAddress), "already exist");

        validatorIdsOf[_poolAddress].add(_validatorId);
        rate = _rate;
        totalRTokenSupply = _totalRTokenSupply;
        totalProtocolFee = _totalProtocolFee;
        latestEra = _era;
        eraRate[_era] = _rate;
    }

    function transferAdmin(address _newAdmin) public onlyAdmin {
        require(_newAdmin != address(0), "zero address");
        admin = _newAdmin;
    }

    function transferDelegationBalancer(address _newDelegationBalancer) public onlyAdmin {
        require(_newDelegationBalancer != address(0), "zero address");
        delegationBalancer = _newDelegationBalancer;
    }

    function setParams(
        uint256 _unstakeFeeCommission,
        uint256 _protocolFeeCommission,
        uint256 _minStakeAmount,
        uint256 _rateChangeLimit,
        uint256 _eraSeconds,
        uint256 _eraOffset
    ) external onlyAdmin {
        unstakeFeeCommission = _unstakeFeeCommission == 1 ? unstakeFeeCommission : _unstakeFeeCommission;
        protocolFeeCommission = _protocolFeeCommission == 1 ? protocolFeeCommission : _protocolFeeCommission;
        minStakeAmount = _minStakeAmount == 0 ? minStakeAmount : _minStakeAmount;
        rateChangeLimit = _rateChangeLimit == 0 ? rateChangeLimit : _rateChangeLimit;
        eraSeconds = _eraSeconds == 0 ? eraSeconds : _eraSeconds;
        eraOffset = _eraOffset == 0 ? eraOffset : _eraOffset;
    }

    function addStakePool(address _poolAddress) external onlyAdmin {
        require(bondedPools.add(_poolAddress), "pool exist");
    }

    function rmStakePool(address _poolAddress) external onlyAdmin {
        uint256[] memory validators = getValidatorIdsOf(_poolAddress);
        for (uint256 j = 0; j < validators.length; ++j) {
            require(IStakePool(_poolAddress).getTotalStakeOnValidator(validators[j]) == 0, "delegate not empty");

            validatorIdsOf[_poolAddress].remove(validators[j]);
        }

        require(bondedPools.remove(_poolAddress), "pool not exist");
    }

    function approve(address _poolAddress, uint256 _amount) external onlyAdmin {
        IStakePool(_poolAddress).approveForStakeManager(erc20TokenAddress, _amount);
    }

    function withdrawProtocolFee(address _to) external onlyAdmin {
        IERC20(rTokenAddress).safeTransfer(_to, IERC20(rTokenAddress).balanceOf(address(this)));
    }

    // ------ delegation balancer

    function redelegate(
        address _poolAddress,
        uint256 _srcValidatorId,
        uint256 _dstValidatorId,
        uint256 _amount
    ) external onlyDelegationBalancer {
        require(validatorIdsOf[_poolAddress].contains(_srcValidatorId), "val not exist");
        require(_srcValidatorId != _dstValidatorId, "val duplicate");
        require(_amount > 0, "amount zero");

        if (!validatorIdsOf[_poolAddress].contains(_dstValidatorId)) {
            validatorIdsOf[_poolAddress].add(_dstValidatorId);
        }

        IStakePool(_poolAddress).redelegate(_srcValidatorId, _dstValidatorId, _amount);

        if (IStakePool(_poolAddress).getTotalStakeOnValidator(_srcValidatorId) == 0) {
            validatorIdsOf[_poolAddress].remove(_srcValidatorId);
        }
    }

    // ----- staker operation

    function stake(uint256 _stakeAmount) external {
        stakeWithPool(bondedPools.at(0), _stakeAmount);
    }

    function unstake(uint256 _rTokenAmount) external {
        unstakeWithPool(bondedPools.at(0), _rTokenAmount);
    }

    function withdraw() external {
        withdrawWithPool(bondedPools.at(0));
    }

    function stakeWithPool(address _poolAddress, uint256 _stakeAmount) public {
        require(_stakeAmount >= minStakeAmount, "amount not enough");
        require(bondedPools.contains(_poolAddress), "pool not exist");

        uint256 rTokenAmount = _stakeAmount.mul(1e18).div(rate);

        // transfer erc20 token
        IERC20(erc20TokenAddress).safeTransferFrom(msg.sender, _poolAddress, _stakeAmount);

        // mint rtoken
        totalRTokenSupply = totalRTokenSupply.add(rTokenAmount);
        IERC20MintBurn(rTokenAddress).mint(msg.sender, rTokenAmount);

        // cache reward
        uint256 targetValidator = getValidatorIdsOf(_poolAddress)[0];
        uint256 newReward = IStakePool(_poolAddress).getLiquidRewards(targetValidator);
        if (newReward > 0) {
            undelegateRewardOf[_poolAddress] = undelegateRewardOf[_poolAddress].add(newReward);
        }

        // delegate
        IStakePool(_poolAddress).delegate(targetValidator, _stakeAmount);

        emit Stake(msg.sender, _poolAddress, targetValidator, _stakeAmount, rTokenAmount);
    }

    function unstakeWithPool(address _poolAddress, uint256 _rTokenAmount) public {
        require(_rTokenAmount > 0, "rtoken amount zero");
        require(bondedPools.contains(_poolAddress), "pool not exist");
        require(unstakesOfUser[msg.sender].length() <= 100, "unstake number limit"); //todo test max limit number

        uint256 unstakeFee = _rTokenAmount.mul(unstakeFeeCommission).div(1e18);
        uint256 leftRTokenAmount = _rTokenAmount.sub(unstakeFee);
        uint256 tokenAmount = leftRTokenAmount.mul(rate).div(1e18);

        // burn rtoken
        IERC20MintBurn(rTokenAddress).burnFrom(msg.sender, leftRTokenAmount);
        totalRTokenSupply = totalRTokenSupply.sub(leftRTokenAmount);

        // protocol fee
        totalProtocolFee = totalProtocolFee.add(unstakeFee);
        IERC20(rTokenAddress).safeTransferFrom(msg.sender, address(this), unstakeFee);

        // undelegate
        (int256[] memory emitValidators, int256[] memory emitUnstakeIndexList) = undelegate(
            _poolAddress,
            getValidatorIdsOf(_poolAddress),
            tokenAmount
        );

        emit Unstake(
            msg.sender,
            _poolAddress,
            emitValidators,
            tokenAmount,
            _rTokenAmount,
            leftRTokenAmount,
            emitUnstakeIndexList
        );
    }

    function undelegate(
        address poolAddress,
        uint256[] memory validators,
        uint256 needUndelegate
    ) private returns (int256[] memory, int256[] memory) {
        int256[] memory emitValidators = new int256[](validators.length);
        int256[] memory emitUnstakeIndexList = new int256[](validators.length);
        for (uint256 j = 0; j < validators.length; ++j) {
            emitValidators[j] = -1;
            emitUnstakeIndexList[j] = -1;
            if (needUndelegate == 0) {
                continue;
            }

            uint256 totalStaked = IStakePool(poolAddress).getTotalStakeOnValidator(validators[j]);

            uint256 unbondAmount;
            if (needUndelegate < totalStaked) {
                unbondAmount = needUndelegate;
                needUndelegate = 0;
            } else {
                unbondAmount = totalStaked;
                needUndelegate = needUndelegate.sub(totalStaked);
            }

            if (unbondAmount > 0) {
                // cache reward
                uint256 newReward = IStakePool(poolAddress).getLiquidRewards(validators[j]);
                if (newReward > 0) {
                    undelegateRewardOf[poolAddress] = undelegateRewardOf[poolAddress].add(newReward);
                }

                IStakePool(poolAddress).undelegate(validators[j], unbondAmount);

                // unstake info
                uint256 willUseUnstakeIndex = nextUnstakeIndex;
                nextUnstakeIndex = willUseUnstakeIndex.add(1);

                unstakeAtIndex[willUseUnstakeIndex] = UnstakeInfo({
                    pool: poolAddress,
                    validator: validators[j],
                    receiver: msg.sender,
                    amount: unbondAmount,
                    nonce: IStakePool(poolAddress).unbondNonces(validators[j])
                });
                unstakesOfUser[msg.sender].add(willUseUnstakeIndex);

                emitValidators[j] = int256(validators[j]);
                emitUnstakeIndexList[j] = int256(willUseUnstakeIndex);
            }
        }

        require(needUndelegate == 0, "undelegate not enough");
        return (emitValidators, emitUnstakeIndexList);
    }

    function withdrawWithPool(address _poolAddress) public {
        uint256 totalWithdrawAmount;
        uint256 length = unstakesOfUser[msg.sender].length();
        uint256[] memory unstakeIndexList = new uint256[](length);
        int256[] memory emitUnstakeIndexList = new int256[](length);

        for (uint256 i = 0; i < length; ++i) {
            unstakeIndexList[i] = unstakesOfUser[msg.sender].at(i);
        }

        IGovStakeManager govStakeManager = IGovStakeManager(govStakeManagerAddress);
        uint256 withdrawDelay = govStakeManager.withdrawalDelay();
        uint256 epoch = govStakeManager.epoch();

        for (uint256 i = 0; i < length; ++i) {
            uint256 unstakeIndex = unstakeIndexList[i];
            UnstakeInfo memory unstakeInfo = unstakeAtIndex[unstakeIndex];

            if (
                !IStakePool(_poolAddress).unstakeClaimTokens(
                    unstakeInfo.validator,
                    unstakeInfo.nonce,
                    withdrawDelay,
                    epoch
                )
            ) {
                emitUnstakeIndexList[i] = -1;
                continue;
            }

            require(unstakesOfUser[msg.sender].remove(unstakeIndex), "already withdrawed");

            totalWithdrawAmount = totalWithdrawAmount.add(unstakeInfo.amount);
            emitUnstakeIndexList[i] = int256(unstakeIndex);
        }

        if (totalWithdrawAmount > 0) {
            IStakePool(_poolAddress).withdrawForStaker(erc20TokenAddress, msg.sender, totalWithdrawAmount);
        }

        emit Withdraw(msg.sender, _poolAddress, totalWithdrawAmount, emitUnstakeIndexList);
    }

    // ----- permissionless

    function newEra() external {
        uint256 era = latestEra.add(1);
        require(currentEra() >= era, "calEra not match");

        // update era
        latestEra = era;

        uint256 totalNewReward;
        uint256 newTotalActive;
        address[] memory poolList = getBondedPools();
        for (uint256 i = 0; i < poolList.length; ++i) {
            address poolAddress = poolList[i];

            uint256[] memory validators = getValidatorIdsOf(poolAddress);

            // newReward
            uint256 poolNewReward = IStakePool(poolAddress).checkAndWithdrawRewards(validators);

            poolNewReward = poolNewReward.add(undelegateRewardOf[poolAddress]);
            undelegateRewardOf[poolAddress] = 0;

            uint256 poolBalance = IERC20(erc20TokenAddress).balanceOf(poolAddress);
            if (poolNewReward > poolBalance) {
                poolNewReward = poolBalance;
            }

            totalNewReward = totalNewReward.add(poolNewReward);

            // delegate new reward
            if (poolNewReward > 0) {
                IStakePool(poolAddress).delegate(validators[0], poolNewReward);

                emit DelegateReward(poolAddress, validators[0], poolNewReward);
            }

            // cal total active
            uint256 newPoolActive = IStakePool(poolAddress).getTotalStakeOnValidators(validators);
            newTotalActive = newTotalActive.add(newPoolActive);
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
        uint256 newRate = newTotalActive.mul(1e18).div(totalRTokenSupply);
        uint256 rateChange = newRate > rate ? newRate.sub(rate) : rate.sub(newRate);
        require(rateChange.mul(1e18).div(rate) < rateChangeLimit, "rate change over limit");

        rate = newRate;
        eraRate[era] = newRate;

        emit ExecuteNewEra(era, newRate);
    }
}
