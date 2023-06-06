pragma solidity 0.7.6;
// SPDX-License-Identifier: GPL-3.0-only

import {SafeERC20, IERC20, SafeMath} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../balancer-metastable-rate-providers/interfaces/IRateProvider.sol";
import "./Types.sol";
import "./IStakePool.sol";
import "./IERC20MintBurn.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/EnumerableSet.sol";

contract StakeManager is IRateProvider {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    address public admin;
    address public rTokenAddress;
    address public erc20TokenAddress;
    uint256 public minStakeAmount;
    uint256 public unstakeFeeCommission; // decimals 18
    uint256 public protocolFeeCommission; // decimals 18
    uint256 public rateChangeLimit; // decimals 18
    uint256 public eraSeconds;
    uint256 public eraOffset;
    uint256 public unbondingDuration;

    uint256 public latestEra;
    uint256 private rate; // decimals 18
    uint256 public totalRTokenSupply;
    uint256 public totalProtocolFee;

    EnumerableSet.AddressSet bondedPools;
    mapping(address => PoolInfo) public poolInfoOf;
    mapping(address => EnumerableSet.UintSet) validatorIdsOf;
    mapping(address => mapping(uint256 => uint256)) maxClaimedNonceOf; // pool => validator Id => max claimed nonce
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
    event SetUnbondingDuration(uint256 unbondingDuration);
    event Delegate(address pool, address validator, uint256 amount);
    event Undelegate(address pool, address validator, uint256 amount);

    // init
    function init(address _rTokenAddress, address _erc20TokenAddress, uint256 _unbondingDuration) public {
        require(admin == address(0), "already init");

        admin = msg.sender;
        rTokenAddress = _rTokenAddress;
        erc20TokenAddress = _erc20TokenAddress;
        unbondingDuration = _unbondingDuration;

        minStakeAmount = 1e12;
        rateChangeLimit = 1e15;
        unstakeFeeCommission = 2e15;
        protocolFeeCommission = 1e17;
        eraSeconds = 600;
        eraOffset = 18033;
    }

    // modifer
    modifier onlyAdmin() {
        require(admin == msg.sender, "caller is not admin");
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
        uint256 _validatorId,
        uint256 _govDelegated,
        uint256 _bond,
        uint256 _unbond,
        uint256 _rate,
        uint256 _totalRTokenSupply,
        uint256 _totalProtocolFee,
        uint256 _era
    ) external onlyAdmin {
        require(rate == 0, "already migrate");
        require(bondedPools.add(_poolAddress), "already exist");

        validatorIdsOf[_poolAddress].add(_validatorId);
        poolInfoOf[_poolAddress] = PoolInfo({era: _era, bond: _bond, unbond: _unbond, active: _govDelegated});
        rate = _rate;
        totalRTokenSupply = _totalRTokenSupply;
        totalProtocolFee = _totalProtocolFee;
        latestEra = _era;
        eraRate[_era] = _rate;
    }

    function setParams(
        uint256 _unstakeFeeCommission,
        uint256 _protocolFeeCommission,
        uint256 _minStakeAmount,
        uint256 _unbondingDuration,
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

        uint256[] memory validators = getValidatorIdsOf(_poolAddress);
        for (uint256 j = 0; j < validators.length; ++j) {
            require(IStakePool(_poolAddress).getTotalStakeOnValidator(validators[j]) == 0, "delegate not empty");
        }

        require(bondedPools.remove(_poolAddress), "pool not exist");
    }

    function redelegate(
        address _poolAddress,
        uint256 _srcValidatorId,
        uint256 _dstValidatorId,
        uint256 _amount
    ) external onlyAdmin {
        IStakePool(_poolAddress).migrateDelegation(_srcValidatorId, _dstValidatorId, _amount);
        if (IStakePool(_poolAddress).getTotalStakeOnValidator(_srcValidatorId) == 0) {
            validatorIdsOf[_poolAddress].remove(_srcValidatorId);
        }
    }

    function withdrawProtocolFee(address _to) external onlyAdmin {
        IERC20(rTokenAddress).safeTransfer(_to, IERC20(rTokenAddress).balanceOf(address(this)));
    }

    function approve(address _poolAddress, uint256 _amount) external onlyAdmin {
        IStakePool(_poolAddress).approveForStakeManager(erc20TokenAddress, _amount);
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

        // update pool
        PoolInfo storage poolInfo = poolInfoOf[_poolAddress];
        poolInfo.bond = poolInfo.bond.add(_stakeAmount);
        poolInfo.active = poolInfo.active.add(_stakeAmount);

        // transfer erc20 token
        IERC20(erc20TokenAddress).safeTransferFrom(msg.sender, _poolAddress, _stakeAmount);

        // mint rtoken
        totalRTokenSupply = totalRTokenSupply.add(rTokenAmount);
        IERC20MintBurn(rTokenAddress).mint(msg.sender, rTokenAmount);

        emit Stake(msg.sender, _poolAddress, _stakeAmount, rTokenAmount);
    }

    function unstakeWithPool(address _poolAddress, uint256 _rTokenAmount) public {
        require(_rTokenAmount > 0, "rtoken amount zero");
        require(bondedPools.contains(_poolAddress), "pool not exist");
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
            IStakePool(_poolAddress).withdrawForStaker(erc20TokenAddress, msg.sender, totalWithdrawAmount);
        }

        emit Withdraw(msg.sender, _poolAddress, totalWithdrawAmount, unstakeIndexList);
    }

    // ----- permissionless

    function newEra() external {
        uint256 _era = latestEra.add(1);
        require(currentEra() >= _era, "calEra not match");

        // update era
        latestEra = _era;

        uint256 totalNewReward;
        uint256 newTotalActive;
        address[] memory poolList = getBondedPools();
        for (uint256 i = 0; i < poolList.length; ++i) {
            address poolAddress = poolList[i];

            uint256[] memory validators = getValidatorIdsOf(poolAddress);

            // newReward
            uint256 poolNewReward = IStakePool(poolAddress).checkAndWithdrawRewards(validators);
            totalNewReward = totalNewReward.add(poolNewReward);

            // unstakeClaimTokens
            for (uint256 j = 0; j < validators.length; ++j) {
                uint256 oldClaimedNonce = maxClaimedNonceOf[poolAddress][validators[j]];
                uint256 newClaimedNonce = IStakePool(poolAddress).unstakeClaimTokens_new(
                    validators[j],
                    oldClaimedNonce
                );
                if (newClaimedNonce > oldClaimedNonce) {
                    maxClaimedNonceOf[poolAddress][validators[j]] = newClaimedNonce;
                }
            }

            // bond or unbond
            PoolInfo memory poolInfo = poolInfoOf[poolAddress];
            if (poolInfo.bond.add(poolNewReward) > poolInfo.unbond) {
                IStakePool(poolAddress).buyVoucher(
                    validators[0],
                    poolInfo.bond.add(poolNewReward).sub(poolInfo.unbond)
                );
            } else if (poolInfo.bond.add(poolNewReward) < poolInfo.unbond) {
                uint256 needUndelegate = poolInfo.unbond.sub(poolInfo.bond.add(poolNewReward));

                for (uint256 j = 0; j < validators.length; ++j) {
                    if (needUndelegate == 0) {
                        break;
                    }
                    uint256 totalStaked = IStakePool(poolAddress).getTotalStakeOnValidator(validators[j]);

                    if (needUndelegate < totalStaked) {
                        IStakePool(poolAddress).sellVoucher_new(validators[j], needUndelegate);

                        needUndelegate = 0;
                    } else {
                        IStakePool(poolAddress).sellVoucher_new(validators[j], totalStaked);
                        needUndelegate = needUndelegate.sub(totalStaked);
                    }
                }
            }

            // cal total active
            uint256 newPoolActive = IStakePool(poolAddress).getTotalStakeOnValidators(validators);
            newTotalActive = newTotalActive.add(newPoolActive);

            // update pool state
            poolInfo.era = latestEra;
            poolInfo.active = newPoolActive;
            poolInfo.bond = 0;
            poolInfo.unbond = 0;

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

        // update rate
        uint256 newRate = newTotalActive.mul(1e18).div(totalRTokenSupply);
        uint256 rateChange = newRate > rate ? newRate.sub(rate) : rate.sub(newRate);
        require(rateChange.mul(1e18).div(rate) < rateChangeLimit, "rate change over limit");

        rate = newRate;
        eraRate[_era] = newRate;

        emit ExecuteNewEra(_era, newRate);
    }
}
