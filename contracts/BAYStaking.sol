// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

interface IsBAYToken {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/**
 * @title BAYStaking
 * @notice Flexible-only staking with unbonding delay and fast withdraw penalty
 * @dev Users stake BAY -> mint sBAY 1:1 (votes). No lock boosts, fair governance.
 *      Standard withdraw available 7 days after unstake request.
 *      Fast withdraw available immediately with 25% penalty that gets re-injected as rewards.
 */
contract BAYStaking is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    struct Unbond {
        uint256 amount;
        uint64 claimableAt;
    }

    struct DelegateSig {
        uint256 nonce;
        uint256 expiry;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct PermitParams {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // Immutable contracts
    IERC20 public immutable bayToken;
    IsBAYToken public immutable sBAYToken;

    // Staking state
    mapping(address => uint256) public balances; // User staked amounts
    uint256 public totalStaked; // Total staked BAY

    // Unbonding state
    mapping(address => Unbond[]) public userUnbonds;

    // Reward accounting (Synthetix-style)
    uint256 public rewardRate;
    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateTime;
    uint256 public periodFinish;

    // User reward tracking
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    // Configuration constants
    uint64 public constant UNBONDING_PERIOD = 7 days;
    uint256 public constant EARLY_EXIT_PENALTY_BPS = 2500; // 25%
    uint256 public constant PENALTY_DISTRIBUTION_WINDOW = 7 days;

    // Emission modes
    enum EmissionMode { Fixed, TopUp }
    EmissionMode public emissionMode;

    // Fixed emission parameters
    uint256 public emissionPerSec;
    uint64 public emissionStart;
    uint64 public emissionEnd;

    // Constants
    uint256 private constant SCALE = 1e18;
    uint256 private constant BPS_DENOMINATOR = 10000;

    // Events
    event Staked(address indexed user, uint256 amount);
    event UnstakeRequested(address indexed user, uint256 amount, uint256 indexed unbondIndex, uint64 claimableAt);
    event Withdrawn(address indexed user, uint256 amount, uint256 indexed unbondIndex, bool isFullWithdrawal);
    event UnbondRemoved(address indexed user, uint256 indexed removedIndex, uint256 swappedFromIndex);
    event FastWithdraw(address indexed user, uint256 amount, uint256 penalty, uint256 netAmount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward, uint256 duration);
    event EmissionConfigured(EmissionMode mode, uint256 emissionPerSec, uint64 start, uint64 end);

    // Errors
    error ZeroAmount();
    error InsufficientBalance();
    error InvalidUnbondIndex();
    error UnbondNotReady();
    error InvalidEmissionPeriod();
    error NotTopUpMode();

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    constructor(
        address _bayToken,
        address _sBAYToken,
        address _owner
    ) Ownable(_owner) {
        bayToken = IERC20(_bayToken);
        sBAYToken = IsBAYToken(_sBAYToken);
        lastUpdateTime = block.timestamp;
        emissionMode = EmissionMode.TopUp; // Default to top-up mode
    }

    /**
     * @notice Stake BAY tokens (flexible only, no lock options)
     * @param amount Amount to stake
     * @param sig Optional delegation signature for one-click self-delegate
     * @param permit Optional permit parameters for gasless approval
     */
    function stake(
        uint256 amount,
        DelegateSig calldata sig,
        PermitParams calldata permit
    ) external nonReentrant whenNotPaused updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();

        // Handle permit if provided
        if (permit.deadline != 0) {
            IERC20Permit(address(bayToken)).permit(
                msg.sender,
                address(this),
                amount,
                permit.deadline,
                permit.v,
                permit.r,
                permit.s
            );
        }

        // Transfer BAY tokens (measure actual received for fee-on-transfer tokens)
        uint256 balanceBefore = bayToken.balanceOf(address(this));
        bayToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 actualAmount = bayToken.balanceOf(address(this)) - balanceBefore;

        // Mint sBAY 1:1 (for voting power)
        sBAYToken.mint(msg.sender, actualAmount);

        // Handle delegation if signature provided
        if (sig.expiry != 0) {
            sBAYToken.delegateBySig(
                msg.sender, // Self-delegate
                sig.nonce,
                sig.expiry,
                sig.v,
                sig.r,
                sig.s
            );
        }

        // Update balances
        balances[msg.sender] += actualAmount;
        totalStaked += actualAmount;

        emit Staked(msg.sender, actualAmount);
    }

    /**
     * @notice Request unstake (starts 7-day unbonding period)
     * @param amount Amount to unstake
     */
    function requestUnstake(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        if (balances[msg.sender] < amount) revert InsufficientBalance();

        // Update balances
        balances[msg.sender] -= amount;
        totalStaked -= amount;

        // Burn sBAY tokens
        sBAYToken.burn(msg.sender, amount);

        // Create unbond entry
        uint64 claimableAt = uint64(block.timestamp) + UNBONDING_PERIOD;
        userUnbonds[msg.sender].push(Unbond({
            amount: amount,
            claimableAt: claimableAt
        }));

        uint256 unbondIndex = userUnbonds[msg.sender].length - 1;
        emit UnstakeRequested(msg.sender, amount, unbondIndex, claimableAt);
    }

    /**
     * @notice Withdraw unbonded tokens (after 7-day period)
     * @param unbondIndex Index of unbond entry to withdraw
     * @param amount Amount to withdraw (0 = full amount)
     */
    function withdrawUnbond(uint256 unbondIndex, uint256 amount) external nonReentrant whenNotPaused {
        if (unbondIndex >= userUnbonds[msg.sender].length) revert InvalidUnbondIndex();

        Unbond storage unbond = userUnbonds[msg.sender][unbondIndex];
        if (block.timestamp < unbond.claimableAt) revert UnbondNotReady();

        if (amount == 0) amount = unbond.amount;
        if (amount > unbond.amount) revert InsufficientBalance();

        // Update or remove unbond entry
        bool isFullWithdrawal = (amount == unbond.amount);

        if (isFullWithdrawal) {
            // Remove entire unbond by swapping with last
            uint256 lastIndex = userUnbonds[msg.sender].length - 1;

            if (unbondIndex != lastIndex) {
                userUnbonds[msg.sender][unbondIndex] = userUnbonds[msg.sender][lastIndex];
                emit UnbondRemoved(msg.sender, unbondIndex, lastIndex);
            } else {
                emit UnbondRemoved(msg.sender, unbondIndex, unbondIndex);
            }
            userUnbonds[msg.sender].pop();
        } else {
            // Partial withdrawal
            unbond.amount -= amount;
        }

        // Transfer BAY tokens to user
        bayToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, unbondIndex, isFullWithdrawal);
    }

    /**
     * @notice Fast withdraw with 25% penalty (immediate withdrawal)
     * @param amount Amount to fast withdraw
     */
    function fastWithdraw(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        if (balances[msg.sender] < amount) revert InsufficientBalance();

        // Calculate penalty and net amount
        uint256 penalty = (amount * EARLY_EXIT_PENALTY_BPS) / BPS_DENOMINATOR;
        uint256 netAmount = amount - penalty;

        // Update balances
        balances[msg.sender] -= amount;
        totalStaked -= amount;

        // Burn sBAY tokens
        sBAYToken.burn(msg.sender, amount);

        // Transfer net amount to user
        if (netAmount > 0) {
            bayToken.safeTransfer(msg.sender, netAmount);
        }

        // Re-inject penalty as rewards (penalty stays in contract)
        if (penalty > 0) {
            _notifyRewardAmount(penalty, PENALTY_DISTRIBUTION_WINDOW);
        }

        emit FastWithdraw(msg.sender, amount, penalty, netAmount);
    }

    /**
     * @notice Claim rewards for user
     */
    function claim() external nonReentrant whenNotPaused updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            bayToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /**
     * @notice Claim and compound rewards (restake them)
     */
    function claimAndStake() external nonReentrant whenNotPaused updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;

            // Mint sBAY 1:1 for compounded rewards
            sBAYToken.mint(msg.sender, reward);

            // Update balances
            balances[msg.sender] += reward;
            totalStaked += reward;

            emit RewardPaid(msg.sender, reward);
            emit Staked(msg.sender, reward);
        }
    }

    /**
     * @notice Configure fixed emission mode
     * @param _emissionPerSec Emission rate per second
     * @param _emissionStart Start timestamp
     * @param _emissionEnd End timestamp
     */
    function configureFixedEmission(
        uint256 _emissionPerSec,
        uint64 _emissionStart,
        uint64 _emissionEnd
    ) external onlyOwner updateReward(address(0)) {
        if (_emissionEnd <= _emissionStart) revert InvalidEmissionPeriod();

        emissionMode = EmissionMode.Fixed;
        emissionPerSec = _emissionPerSec;
        emissionStart = _emissionStart;
        emissionEnd = _emissionEnd;

        emit EmissionConfigured(EmissionMode.Fixed, _emissionPerSec, _emissionStart, _emissionEnd);
    }

    /**
     * @notice Switch to top-up emission mode
     */
    function configureTopUpEmission() external onlyOwner updateReward(address(0)) {
        emissionMode = EmissionMode.TopUp;
        emit EmissionConfigured(EmissionMode.TopUp, 0, 0, 0);
    }

    /**
     * @notice Notify reward amount (top-up mode or penalty injection)
     * @param reward Reward amount
     * @param duration Duration in seconds
     */
    function notifyRewardAmount(uint256 reward, uint256 duration) external onlyOwner updateReward(address(0)) {
        if (emissionMode != EmissionMode.TopUp) revert NotTopUpMode();
        _notifyRewardAmount(reward, duration);
    }

    /**
     * @notice Internal function to notify reward amount with leftover rollover
     * @param amount Reward amount
     * @param duration Duration in seconds
     */
    function _notifyRewardAmount(uint256 amount, uint256 duration) internal {
        require(duration > 0, "duration=0");

        uint256 leftover = block.timestamp < periodFinish
            ? (periodFinish - block.timestamp) * rewardRate
            : 0;

        rewardRate = (amount + leftover) / duration;
        periodFinish = block.timestamp + duration;
        lastUpdateTime = block.timestamp;

        emit RewardAdded(amount, duration);
    }

    /**
     * @notice Get user's unbond entries
     * @param user User address
     * @return Array of user unbonds
     */
    function getUserUnbonds(address user) external view returns (Unbond[] memory) {
        return userUnbonds[user];
    }

    /**
     * @notice Calculate earned rewards for user
     * @param account User address
     * @return Earned rewards
     */
    function earned(address account) public view returns (uint256) {
        return (balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / SCALE
            + rewards[account];
    }

    /**
     * @notice Get current reward per token
     * @return Reward per token
     */
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }

        uint256 applicable = lastTimeRewardApplicable();
        if (applicable <= lastUpdateTime) {
            return rewardPerTokenStored;
        }

        uint256 timeElapsed = applicable - lastUpdateTime;
        uint256 currentRate = _getCurrentRewardRate();

        if (currentRate == 0) {
            return rewardPerTokenStored;
        }

        return rewardPerTokenStored + (timeElapsed * currentRate * SCALE) / totalStaked;
    }

    /**
     * @notice Get last applicable reward time
     * @return Last applicable time
     */
    function lastTimeRewardApplicable() public view returns (uint256) {
        if (emissionMode == EmissionMode.Fixed) {
            uint256 effectiveEnd = emissionEnd;
            return block.timestamp < effectiveEnd ? block.timestamp : effectiveEnd;
        } else {
            return block.timestamp < periodFinish ? block.timestamp : periodFinish;
        }
    }

    /**
     * @notice Get current reward rate based on emission mode
     * @return Current reward rate per second
     */
    function _getCurrentRewardRate() internal view returns (uint256) {
        if (emissionMode == EmissionMode.Fixed) {
            // Check if we're in emission period
            if (block.timestamp >= emissionStart && block.timestamp <= emissionEnd) {
                return emissionPerSec;
            } else {
                return 0;
            }
        } else {
            return rewardRate;
        }
    }

    /**
     * @notice Emergency functions for contract management
     */
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw() external onlyOwner whenPaused {
        uint256 balance = bayToken.balanceOf(address(this));
        if (balance > 0) {
            bayToken.safeTransfer(owner(), balance);
        }
    }

    /**
     * @notice Get contract state for debugging
     */
    function getContractState() external view returns (
        uint256 _totalStaked,
        uint256 _rewardRate,
        uint256 _rewardPerTokenStored,
        uint256 _lastUpdateTime,
        uint256 _periodFinish,
        EmissionMode _emissionMode,
        uint256 _emissionPerSec,
        uint64 _emissionStart,
        uint64 _emissionEnd
    ) {
        return (
            totalStaked,
            rewardRate,
            rewardPerTokenStored,
            lastUpdateTime,
            periodFinish,
            emissionMode,
            emissionPerSec,
            emissionStart,
            emissionEnd
        );
    }
}