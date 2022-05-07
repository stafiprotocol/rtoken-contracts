pragma solidity >=0.7.0 <0.9.0;

import "@openzeppelin/contracts/presets/ERC20PresetMinterPauser.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IStakeManager.sol";
import "./interfaces/IPool.sol";

contract StakeManager is
IStakeManager,
ReentrancyGuard,
Ownable
{
    using SafeMath for uint256;

    // events
    event PoolAdded(address indexed poolAddr);
    event Bonded(
        address indexed bonder,
        uint256 value,
        address indexed poolAddr,
        address indexed group
    );
    event Unbonded(
        address indexed from,
        uint256 value,
        address indexed poolAddr,
        address indexed group
    );
    event EpochUpdated(uint256 epoch);

    // Calculate exchange rate using this as the base
    uint256 constant calcBase = 1000000000000000000;

    // Pools store as linklist.
    address internal constant SENTINEL_POOL = address(0x1);
    mapping(address => address) internal poolAddrs;

    // Minimum amount for a single bond transaction
    uint256 public leastBond;
    // Minimum amount for a single unbond transaction
    uint256 public leastUnbond;
    // Count limit of unbonds for a pool
    uint256 public unbondCountLimit;
    // rToken contract
    address public rTokenContract;

    // Expected bonded of poolAddrs
    mapping(address => uint256) public expectedBondeds;
    // Total expected bondeds
    uint256 public totalExpectedBonded;

    struct UnbondDetail {
        // unbonder
        address unbonder;
        // pool address
        address poolAddr;
        // unbond value.
        uint256 value;
        // The timestamp at which the withdrawal becomes available
        uint256 timestamp;
    }

    // unbond state
    enum UnbondState {Unbonded, Withdrawed, Transfered}
    struct UnbondRecord {
        UnbondDetail detail;
        UnbondState state;
    }

    // All unbond records
    mapping(bytes32 => UnbondRecord) public unbondRecords;
    // Unbond records by pool
    mapping(address => bytes32[]) public unbondHashesByPool;
    // Unbond records by pool and account
    mapping(address => mapping(address => bytes32[])) public unbondHashesByAccountAndPool;

    constructor(
        uint256 _leastBond,
        uint256 _leastUnbond,
        uint256 _unbondCountLimit,
        address _rTokenContract
    ) {
        leastBond = _leastBond;
        leastUnbond = _leastUnbond;
        unbondCountLimit = _unbondCountLimit;
        rTokenContract = _rTokenContract;
    }

    // todo register pool as Account

    function addPool(address poolAddr) public onlyOwner {
        // poolAddr address cannot be null, the sentinel or the Manager itself.
        require(poolAddr != address(0) && poolAddr != SENTINEL_POOL, "Invalid poolAddr provided");
        // No duplicate poolAddrs allowed.
        require(!isPool(poolAddr), "Pool already added");

        if (pools[SENTINEL_POOL] == address(0)) {
            poolAddrs[SENTINEL_POOL] = poolAddr;
            poolAddrs[poolAddr] = SENTINEL_POOL;
        } else {
            poolAddrs[poolAddr] = poolAddrs[SENTINEL_POOL];
            poolAddrs[SENTINEL_POOL] = poolAddr;
        }
        emit PoolAdded(poolAddr);
    }

    /**
    * @notice bond `value` to get rToken, the `value` will be bonded.
    * @param poolAddr The poolAddr to bond.
    * @param group/lesser/greater are needed for `vote` of CELO.
    */
    function bond(address poolAddr, adderss group, address lesser, address greater) external payable {
        require(isPool(poolAddr), "Invalid poolAddr");
        require(msg.value >= leastBond, "Bond value should bigger than leastBond");

        // bond and vote
        IPool pool = IPool(poolAddr);
        (bool success, ) = pool.bond{value: msg.value}();
        require(success, "Pool bond failed");
        bool voted = pool.vote(group, msg.value, lesser, greater);
        require(voted, "Pool vote failed");

        // mint rToken
        uint256 rValue = tokenToRToken(msg.value);
        ERC20PresetMinterPauser rToken = ERC20PresetMinterPauser(rTokenContract);
        rToken.mint(rValue, msg.sender);

        expectedBondeds[poolAddr] = expectedBondeds[poolAddr].add(msg.value);
        totalExpectedBonded = totalExpectedBonded.add(msg.value);
        emit Bonded(msg.sender, msg.value, poolAddr, group);
    }

    /**
    * @notice activate pending votes.
    * @param poolAddr The poolAddr to activate.
    * @param group The validator group that has been voted.
    */
    function activate(address poolAddr, address group) external {
        IPool pool = IPool(poolAddr);
        bool activated = pool.activate(group);
        require(activated, "Pool activate failed");
    }

    /**
    * @notice Unbond `value` active votes for `group`
    * @param poolAddr The poolAddr to unbond.
    * @param group The validator group to revoke votes from.
    * @param rvalue The number of rToken.
    * @param lesser The group receiving fewer votes than the group for which the vote was revoked,
    *   or 0 if that group has the fewest votes of any validator group.
    * @param greater The group receiving more votes than the group for which the vote was revoked,
    *   or 0 if that group has the most votes of any validator group.
    * @param index The index of the group in the account's voting list.
    * @return True upon success.
    * @dev Fails if the account has not voted on a validator group.
    */
    function unbond(address poolAddr, address group, uint256 rvalue, address lesser, address greater, uint256 index) external {
        require(isPool(poolAddr), "Invalid poolAddr");
        require(value >= leastUnbond, "Unbond value should bigger than leastUnbond");

        bytes32[] storage poolUnbondHashes = unbondHashesByPool[poolAddr];
        require(
            unbondCountLimit == 0 ||
            poolUnbondHashes.length < unbondCountLimit,
            "Too much unbond records for a pool"
        );
        uint256 value = rTokenToToken(rvalue);
        require(value <= expectedBondeds[poolAddr], "Pool expected bonded is not enough");

        IPool pool = IPool(poolAddr);
        uint256 poolVotes = pool.getTotalVotes(group);
        require(value <= poolVotes, "Pool votes is not enough");

        // burn rToken
        ERC20PresetMinterPauser rToken = ERC20PresetMinterPauser(rTokenContract);
        rToken.burn(rValue, msg.sender);

        // unbond and return the timestamp of latest pending withdraw
        uint256 timestamp = pool.unbond(group, value, lesser, greater, index);
        UnbondDetail detail = UnbondDetail(msg.sender, poolAddr, value, timestamp);
        bytes32 unbondHash = keccak256(abi.encodePacked(poolAddr, value, timestamp));
        UnbondRecord storage record = UnbondRecord(detail, UnbondState.Unbonded);
        unbondRecords[unbondHash] = record;
        poolUnbondHashes.push(unbondHash);
        unbondHashesByAccountAndPool[msg.sender][poolAddr].push(unbondHash);

        expectedBondeds[poolAddr] = expectedBondeds[poolAddr].sub(value);
        totalExpectedBonded = totalExpectedBonded.sub(value);
        emit Unbonded(msg.sender, value, poolAddr, group);
    }

    function withdraw(address poolAddr) external nonReentrant {
        bytes32[] storage unbondHashes = unbondHashesByAccountAndPool[msg.sender][poolAddr];
        require(unbondHashes.length > 0, "No unbond record to withdraw");
        IPool pool = IPool(poolAddr);
        (uint256[] memory values, uint256[] memory timestamps) = pool.withdraw();
        require(values.length == timestamps.length, "Length of values should be equal to length of timestamps");
        for (uint256 i = 0; i < values.length; i = i.add(1)) {
            bytes32 unbondHash = keccak256(abi.encodePacked(poolAddr, values[i], timestamps[i]));
            UnbondRecord storage record = unbondRecords[unbondHash];
            record.state = UnbondState.Withdrawed;
        }

        // total value to be transferred back to msg.sender
        uint256 total = 0;
        uint256 i = 0;
        while (i < unbondHashes.length) {
            bytes32 unbondHash = unbondHashes[i];
            UnbondRecord storage record = unbondRecords[unbondHash];
            if (record.state == UnbondState.Withdrawed) {
                total = total.add(record.detail.value);
                record.state = UnbondState.Transfered;
            }

            if (record.state == UnbondState.Transfered) {
                unbondHashes[i] = unbondHashes[unbondHashes.length - 1];
                unbondHashes.pop();
                continue;
            }

            i = i.add(1);
        }

        bytes32[] storage poolUnbondHashes = unbondHashesByPool[poolAddr];
        i = 0;
        while (i < poolUnbondHashes.length) {
            bytes32 unbondHash = poolUnbondHashes[i];
            UnbondRecord memory record = unbondRecords[unbondHash];

            if (record.state == UnbondState.Transfered) {
                poolUnbondHashes[i] = poolUnbondHashes[poolUnbondHashes.length - 1];
                poolUnbondHashes.pop();
                continue;
            }

            i = i.add(1);
        }

        // todo transfer back
        pool.transfer(total);
    }

    // Calculate the number of rToken based on the number of the origin Token
    function tokenToRToken(uint256 amount) public view returns (uint256) {
        // Use 1:1 ratio if no rToken is minted
        if (totalExpectedBonded == 0) { return amount; }
        ERC20PresetMinterPauser rToken = ERC20PresetMinterPauser(_rTokenContract);
        uint256 rTotal = rToken.totalSupply();
        // Calculate and return
        return amount.mul(rTotal).div(totalExpectedBonded);
    }

    // Calculate the number of Token based on the number of rToken
    function rTokenToToken(uint256 amount) public view returns (uint256) {
        ERC20PresetMinterPauser rToken = ERC20PresetMinterPauser(_rTokenContract);
        uint256 rTotal = rToken.totalSupply();
        // Use 1:1 ratio if no rToken is minted
        if (rTotal == 0) { return amount; }
        // Calculate and return
        return amount.mul(total).div(rTotal);
    }

    function getTotalBonded() public view returns (uint256) {
        uint256 total = 0;
        address currentPool = poolAddrs[SENTINEL_POOL];
        while (currentPool != SENTINEL_POOL) {
            IPool pool = IPool(currentPool);
            total = add(total, poolAddr.getTotalBonded());
            currentPool = poolAddrs[currentPool];
        }

        return total;
    }

    function isPool(address poolAddr) public view returns (bool) {
        return poolAddr != SENTINEL_POOL && poolAddrs[poolAddr] != address(0);
    }

    /// getPools Returns array of poolAddrs.
    function getPools() public view returns (address[] memory) {
        address[] memory array = new address[](poolCount);

        // populate return array
        uint256 index = 0;
        address currentPool = poolAddrs[SENTINEL_POOL];
        while (currentPool != SENTINEL_POOL) {
            array[index] = currentPool;
            currentPool = poolAddrs[currentPool];
            index++;
        }
        return array;
    }

    function getExchangeRate() external view returns (uint256) {
        ERC20PresetMinterPauser rToken = ERC20PresetMinterPauser(_rTokenContract);
        uint256 rTotal = rToken.totalSupply();

        if (rTotal == 0) {
            return calcBase;
        }

        return calcBase.mul(totalExpectedBonded).div(rTotal);
    }
}