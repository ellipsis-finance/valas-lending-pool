pragma solidity 0.7.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";


interface IFactory {
    function admin() external view returns (address);
    function get_base_pool(address pool) external view returns (address);
    function get_lp_token(address pool) external view returns (address);
}

interface IStableSwapValas {
    function claim_rewards() external;
}

interface IRewardsToken {
    function notifyRewardAmount(address reward, uint256 amount) external;
}


// LP Token with rewards capability for http://ellipsis.finance/
// ERC20 that represents a deposit into an Ellipsis pool and allows 3rd-party incentives for token holders
// Based on SNX MultiRewards by iamdefinitelyahuman - https://github.com/iamdefinitelyahuman/multi-rewards
contract ValasRewardsToken is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct Reward {
        address rewardsDistributor;
        uint256 rewardsDuration;
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }
    struct MetaPoolData {
        uint256 lastClaim;
        address lpToken;
    }

    /* ========== STATE VARIABLES ========== */

    string public symbol;
    string public name;
    uint256 public constant decimals = 18;
    uint256 public totalSupply;
    uint256 public rewardCount;

    address public minter;
    IFactory public factory;

    mapping(address => Reward) public rewardData;
    address[] public rewardTokens;

    // user -> reward token -> amount
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(address => mapping(address => uint256)) public rewards;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public depositedBalanceOf;

    mapping(address => bool) public depositContracts;

    // owner -> spender -> amount
    mapping(address => mapping(address => uint256)) public allowance;

    mapping(address => MetaPoolData) metapoolClaims;

    address constant VALAS = 0xB1EbdD56729940089Ecc3aD0BBEEB12b6842ea6F;
    uint256 constant WEEK = 604800;

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event RewardPaid(address indexed user, address indexed rewardsToken, uint256 reward);
    event RewardsDurationUpdated(address token, uint256 newDuration);
    event Recovered(address token, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /* ========== CONSTRUCTOR ========== */

    constructor(
        string memory _name,
        string memory _symbol,
        address _minter,
        address _factory
    ) {
        name = _name;
        symbol = _symbol;
        minter = _minter;
        factory = IFactory(_factory);
        emit Transfer(address(0), _minter, 0);

        // VALAS is set as the reward token, adding further reward tokens is not possible
        // the contract is optimized for one reward token to minimize gas costs for metapools
        // that use this as their base token
        rewardTokens.push(VALAS);
        rewardData[VALAS].rewardsDistributor = _minter;
        rewardData[VALAS].rewardsDuration = WEEK;
        rewardCount = 1;

    }

    /* ========== ADMIN FUNCTIONS ========== */

    function setDepositContract(address _account, bool _isDepositContract) external onlyOwner {
        require(balanceOf[_account] == 0, "Address has a balance");
        depositContracts[_account] = _isDepositContract;
    }

    // force an update to metapoolClaims (in case someone sent tokens
    // to a metapool LP token address before the token was deployed)
    function refreshMetapoolClaims(address account) external {
        if (factory.get_base_pool(account) == minter) {
            metapoolClaims[account].lpToken = factory.get_lp_token(account);
            metapoolClaims[account].lastClaim = 0;
        } else {
            metapoolClaims[account].lastClaim = uint(-1);
        }
    }

    /* ========== MODIFIERS ========== */

    modifier onlyOwner() {
        require(msg.sender == owner());
        _;
    }

    modifier updateReward(address payable[2] memory accounts) {
        if (accounts[0] != address(0) && rewardData[VALAS].periodFinish + 3600 < block.timestamp + WEEK) {
            // claim VALAS from the pool once per hour
            IStableSwapValas(minter).claim_rewards();
        }

        rewardData[VALAS].rewardPerTokenStored = rewardPerToken(VALAS);
        rewardData[VALAS].lastUpdateTime = lastTimeRewardApplicable(VALAS);
        for (uint x = 0; x < accounts.length; x++) {
            address account = accounts[x];
            if (account == address(0)) break;
            if (depositContracts[account]) continue;

            // check if `account` is a metapool that uses this LP token as a base pool
            uint256 lastClaim = metapoolClaims[account].lastClaim;
            if (lastClaim == 0) {
                if (factory.get_base_pool(account) == minter) {
                    metapoolClaims[account].lpToken = factory.get_lp_token(account);
                } else {
                    lastClaim = uint(-1);
                    metapoolClaims[account].lastClaim = lastClaim;
                }
            }

            uint256 reward = earned(account, VALAS);
            userRewardPerTokenPaid[account][VALAS] = rewardData[VALAS].rewardPerTokenStored;
            if (lastClaim < block.timestamp - 3600 && reward > 0) {
                // if account is a metapool and the last claim was > 1 hour ago, push the rewards
                rewards[account][VALAS] = 0;
                metapoolClaims[account].lastClaim = block.timestamp;
                IERC20(VALAS).approve(metapoolClaims[account].lpToken, reward);
                IRewardsToken(metapoolClaims[account].lpToken).notifyRewardAmount(VALAS, reward);
            } else {
                rewards[account][VALAS] = reward;
            }
        }
        _;
    }

    /* ========== VIEWS ========== */

    function owner() public view returns (address) {
        return factory.admin();
    }

    function lastTimeRewardApplicable(address _rewardsToken) public view returns (uint256) {
        return Math.min(block.timestamp, rewardData[_rewardsToken].periodFinish);
    }

    function rewardPerToken(address _rewardsToken) public view returns (uint256) {
        Reward storage reward = rewardData[_rewardsToken];
        if (totalSupply == 0) {
            return reward.rewardPerTokenStored;
        }
        uint256 last = lastTimeRewardApplicable(_rewardsToken);
        return reward.rewardPerTokenStored.add(
            last.sub(reward.lastUpdateTime).mul(reward.rewardRate).mul(1e18).div(totalSupply)
        );
    }

    function earned(address account, address _rewardsToken) public view returns (uint256) {
        if (depositContracts[account]) return 0;
        uint256 balance = balanceOf[account].add(depositedBalanceOf[account]);
        uint256 perToken = rewardPerToken(_rewardsToken).sub(userRewardPerTokenPaid[account][_rewardsToken]);
        return balance.mul(perToken).div(1e18).add(rewards[account][_rewardsToken]);
    }

    function getRewardForDuration(address _rewardsToken) external view returns (uint256) {
        return rewardData[_rewardsToken].rewardRate.mul(rewardData[_rewardsToken].rewardsDuration);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function approve(address _spender, uint256 _value) public returns (bool) {
        allowance[msg.sender][_spender] = _value;
        emit Approval(msg.sender, _spender, _value);
        return true;
    }

    /** shared logic for transfer and transferFrom */
    function _transfer(
        address payable _from,
        address payable _to,
        uint256 _value
    )
        internal
        updateReward([_from, _to])
    {
        require(balanceOf[_from] >= _value, "Insufficient balance");
        balanceOf[_from] = balanceOf[_from].sub(_value);
        balanceOf[_to] = balanceOf[_to].add(_value);

        if (depositContracts[_from]) {
            require(!depositContracts[_to], "Cannot transfer between deposit contracts");
            require(_from == msg.sender, "Cannot use transferFrom on a deposit contract");
            depositedBalanceOf[_to] = depositedBalanceOf[_to].sub(_value);
        } else if (depositContracts[_to]) {
            require(_to == msg.sender, "Deposit contract must call transferFrom to receive tokens");
            depositedBalanceOf[_from] = depositedBalanceOf[_from].add(_value);
        }
        emit Transfer(_from, _to, _value);
    }

    function transfer(address payable _to, uint256 _value) public returns (bool) {
        _transfer(msg.sender, _to, _value);
        return true;
    }

    function transferFrom(
        address payable _from,
        address payable _to,
        uint256 _value
    )
        public
        returns (bool)
    {
        uint256 allowed = allowance[_from][msg.sender];
        require(allowed >= _value, "Insufficient allowance");
        if (allowed != uint256(-1)) {
            allowance[_from][msg.sender] = allowed.sub(_value);
        }
        _transfer(_from, _to, _value);
        return true;
    }

    function getReward() public nonReentrant updateReward([msg.sender, address(0)]) {

        uint256 reward = rewards[msg.sender][VALAS];
        if (reward > 0) {
            rewards[msg.sender][VALAS] = 0;
            IERC20(VALAS).safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, VALAS, reward);
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function notifyRewardAmount(
        address _rewardsToken,
        uint256 reward
    )
        external
        updateReward([address(0), address(0)])
    {
        require(_rewardsToken == VALAS);
        require(rewardData[VALAS].rewardsDistributor == msg.sender);
        // handle the transfer of reward tokens via `transferFrom` to reduce the number
        // of transactions required and ensure correctness of the reward amount
        IERC20(VALAS).safeTransferFrom(msg.sender, address(this), reward);

        if (block.timestamp >= rewardData[VALAS].periodFinish) {
            rewardData[VALAS].rewardRate = reward.div(rewardData[VALAS].rewardsDuration);
        } else {
            uint256 remaining = rewardData[VALAS].periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardData[VALAS].rewardRate);
            rewardData[VALAS].rewardRate = reward.add(leftover).div(rewardData[VALAS].rewardsDuration);
        }

        rewardData[VALAS].lastUpdateTime = block.timestamp;
        rewardData[VALAS].periodFinish = block.timestamp.add(rewardData[VALAS].rewardsDuration);
        emit RewardAdded(reward);
    }

    function mint(
        address payable _to,
        uint256 _value
    )
        external
        updateReward([_to, address(0)])
        returns (bool)
    {
        require(msg.sender == minter);
        balanceOf[_to] = balanceOf[_to].add(_value);
        totalSupply = totalSupply.add(_value);
        emit Transfer(address(0), _to, _value);
        return true;
    }

    function burnFrom(
        address payable _to,
        uint256 _value
    )
        external
        updateReward([_to, address(0)])
        returns (bool)
    {
        require(msg.sender == minter);
        balanceOf[_to] = balanceOf[_to].sub(_value);
        totalSupply = totalSupply.sub(_value);
        emit Transfer(_to, address(0), _value);
        return true;
    }
}
