// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/access/Ownable.sol";
import "solady/src/utils/FixedPointMathLib.sol";

pragma solidity 0.8.26;

/**
 * @title Ledgity Vault Contract
 * @author torof
 * @notice This contract implements a ETH staking and reward distribution system operating in epochs.
 *         Users can provide funds that will be used for derivatives (short put and call options) operations, and in return,
 *         they will receive yield proportionally to their stake.
 * @dev The contract allows users to stake funds, which are locked for a period of time (an epoch).
 *      The contract has a lifecycle that includes opening, running, and terminating epochs, distributing
 *      rewards, and claiming rewards.
 *      Adding and withdrawing funds is possible only when the epoch status is "Open".
 *      Claiming rewards is always possible EXCEPT during the timeframe between when an epoch
 *      starts running and when rewards are allocated for that epoch.
 *
 * Key structures and their importance:
 *
 * The Epoch structure represents a period of staking and reward distribution.
 * It's crucial for managing the lifecycle of funds and rewards, allowing the system
 * to operate in distinct time-bound phases.
 *
 * UserStake tracks individual user stakes across epochs. This structure
 * allows for efficient reward calculations and stake management, ensuring
 * that users' contributions are accurately recorded and rewarded. Stakes can spread across multiple epochs.
 *
 * UserAction records all user activities, including deposits, withdrawals, and claims.
 * This provides a detailed history for auditing and transparency purposes,
 * allowing for a complete view of user interactions with the contract.
 *
 * These structures work together to create a flexible and transparent staking system
 * that can handle staking over multiple epochs, varying reward rates, and detailed user activity tracking.
 * The design allows for precise management of funds and rewards while maintaining
 * a clear record of all operations.
 */

contract Vault is Ownable(msg.sender) {
    struct Epoch {
        uint48 startedAt;
        uint48 endedAt;
        uint48 rewardPercentage;
        uint256 totalValueLocked;
        uint256 totalRewards;
        uint256 totalShares;
        uint256 accumulatedRewardPerShare;
    }

    struct UserStake {
        uint256 epochIn;
        uint256 epochOut; //if 0, the stake is still active
        uint256 stake;
        uint256 shares;
        uint256 rewardDebt;
    }

    struct UserAction {
        uint256 epochNumber;
        ActionType actionType;
        uint256 amount;
        uint256 shares;
        uint256 timestamp;
    }

    enum ActionType { Deposit, Withdraw, Claim }
    enum EpochStatus { Open, Running, Terminated }

    EpochStatus public currentEpochStatus;
    address immutable fundWallet;
    bool public claimableRewards;
    Epoch[] public epochs;
    uint256 public currentEpochId;
    mapping(address => UserStake[]) public userStakes;
    mapping(address => UserAction[]) public userActions;
    mapping(address => uint256) public userRewardShares;
    uint256 public totalRewardShares;

    error WrongPhase(string);
    error NoRewardToClaim();
    error UnClaimableRewards();
    error TransferFailed();
    error NoStakeToExit();
    error NotWithdrawable();

    event Entered(address indexed user, uint256 amount, uint256 shares);
    event Exited(address indexed user, uint256 amount, uint256 shares);
    event RewardsClaimed(address indexed user, uint256 amount);
    event EpochClosed(uint256 indexed epochNumber);
    event RewardsOpened(uint256 indexed epochNumber, uint256 rewardAmount);
    event EpochStarted(uint256 indexed epochNumber);

    constructor(address _fundWallet) {
        // Initialize Epoch 0 as a placeholder that should never be modified
        epochs.push(Epoch(0, 0, 0, 0, 0, 0, 0));
        
        // Initialize Epoch 1 as the first active epoch
        epochs.push(Epoch(0, 0, 0, 0, 0, 0, 0));
        
        fundWallet = _fundWallet;
        currentEpochStatus = EpochStatus.Open;
        currentEpochId = 1; // Start with epoch 1
    }

    function enter() public payable {
        if (currentEpochStatus != EpochStatus.Open) revert WrongPhase("ENTER: only allowed during open phase");

        uint256 newStake = msg.value;
        uint256 newShares = calculateShares(newStake, epochs[currentEpochId].totalValueLocked);

        // Check if user already has an active stake
        if (userStakes[msg.sender].length > 0 && userStakes[msg.sender][userStakes[msg.sender].length - 1].epochOut == 0) {
            UserStake storage existingStake = userStakes[msg.sender][userStakes[msg.sender].length - 1];
            
            // Claim pending rewards before modifying the stake
            _claimRewards(msg.sender);
            
            // Add new stake to existing stake
            existingStake.stake += newStake;
            existingStake.shares += newShares;
        } else {
            // Create a new stake for the user
            userStakes[msg.sender].push(UserStake(currentEpochId, 0, newStake, newShares, 0));
        }

        // Update global and epoch-specific totals
        userRewardShares[msg.sender] += newShares;
        totalRewardShares += newShares;
        epochs[currentEpochId].totalValueLocked += newStake;
        epochs[currentEpochId].totalShares += newShares;

        // Record the user action
        userActions[msg.sender].push(UserAction({
            epochNumber: currentEpochId,
            actionType: ActionType.Deposit,
            amount: newStake,
            shares: newShares,
            timestamp: block.timestamp
        }));

        emit Entered(msg.sender, newStake, newShares);
    }

    function exit(uint256 _amount) public {
        if (currentEpochStatus != EpochStatus.Open) revert WrongPhase("EXIT: only allowed during open phase");

        UserStake storage currentStake = userStakes[msg.sender][userStakes[msg.sender].length - 1];

        if (currentStake.epochOut != 0) revert NoStakeToExit();
        if (_amount > currentStake.stake) revert("EXIT: insufficient balance");

        // Calculate shares to exit based on the proportion of stake being withdrawn
        uint256 sharesToExit = FixedPointMathLib.mulDiv(currentStake.shares, _amount, currentStake.stake);

        // Claim rewards before modifying the stake
        _claimRewards(msg.sender);

        // Update the current stake
        currentStake.stake -= _amount;
        currentStake.shares -= sharesToExit;

        // If it's a full exit, mark the stake as closed
        if (currentStake.stake == 0) {
            currentStake.epochOut = currentEpochId;
        }

        // Update global and epoch-specific totals
        epochs[currentEpochId].totalValueLocked -= _amount;
        epochs[currentEpochId].totalShares -= sharesToExit;
        userRewardShares[msg.sender] -= sharesToExit;
        totalRewardShares -= sharesToExit;

        // Record the user action
        userActions[msg.sender].push(UserAction({
            epochNumber: currentEpochId,
            actionType: ActionType.Withdraw,
            amount: _amount,
            shares: sharesToExit,
            timestamp: block.timestamp
        }));

        // Transfer the withdrawn amount to the user
        (bool success,) = msg.sender.call{value: _amount}("");
        if (!success) revert TransferFailed();

        emit Exited(msg.sender, _amount, sharesToExit);
    }

    function claimRewards() public {
        _claimRewards(msg.sender);
    }

    function _claimRewards(address _user) internal {
        if (!claimableRewards) revert UnClaimableRewards();

        uint256 pending = 0;
        UserStake storage currentStake = userStakes[_user][userStakes[_user].length - 1];

        //if claiming during open phase, the epoch used to calculate rewards should not be current epoch, but previous, since rewards haven't been distributed
        uint256 rewardsEpochId;

        if (currentEpochStatus == EpochStatus.Open) {
            rewardsEpochId = currentEpochId - 1;
        } else {
            rewardsEpochId = currentEpochId;
        }

        // Check if the stake is active or has ended after it began, and if the epoch has rewards to claim
        if (currentStake.epochOut == 0 || currentStake.epochOut > currentStake.epochIn) {
            for (uint j = currentStake.epochIn; j <= rewardsEpochId; j++) {
                uint256 rewardPerShare = epochs[j].accumulatedRewardPerShare;
                pending += FixedPointMathLib.mulDiv(currentStake.shares, rewardPerShare, 1e18) - currentStake.rewardDebt;
                currentStake.rewardDebt = FixedPointMathLib.mulDiv(currentStake.shares, rewardPerShare, 1e18);
            }
        }

        if (pending == 0) revert NoRewardToClaim();

        // Record the claim action
        userActions[_user].push(UserAction({
            epochNumber: currentEpochId,
            actionType: ActionType.Claim,
            amount: pending,
            shares: 0,
            timestamp: block.timestamp
        }));

        (bool success,) = _user.call{value: pending}("");
        if (!success) revert TransferFailed();

        emit RewardsClaimed(_user, pending);
    }

    function calculateShares(uint256 amount, uint256 totalValue) internal pure returns (uint256) {
        if (totalValue == 0) return amount;
        // Calculate shares based on the proportion of new amount to total value
        return FixedPointMathLib.mulDiv(amount, 1e18, totalValue);
    }

    function transitionToNextEpoch() external onlyOwner {
        if (currentEpochStatus != EpochStatus.Running) revert WrongPhase("END EPOCH: can only end a running epoch");

        Epoch storage currentEpoch = epochs[currentEpochId];

        currentEpoch.endedAt = uint48(block.timestamp);
        
        uint256 fundsToTransfer = currentEpoch.totalValueLocked;
        uint256 sharesToTransfer = currentEpoch.totalShares;
        
        // Increment the currentEpochId
        currentEpochId++;
        
        // Start a new epoch with the current TVL and shares
        epochs.push(Epoch(0, 0, 0, fundsToTransfer, 0, sharesToTransfer, 0));
        currentEpochStatus = EpochStatus.Open;

        emit EpochClosed(currentEpochId - 1);
    }

    function openRewards() external payable onlyOwner {
        if (currentEpochStatus != EpochStatus.Running) revert WrongPhase("OPEN REWARDS: must be in running phase");
        Epoch storage currentEpoch = epochs[currentEpochId];
        if (currentEpoch.rewardPercentage != 0) revert NotWithdrawable();

        // Calculate and set the reward percentage
        currentEpoch.rewardPercentage = uint48(FixedPointMathLib.mulDiv(msg.value, 10_000, currentEpoch.totalValueLocked));
        currentEpoch.totalRewards = msg.value;
        
        // Update the accumulated reward per share
        if (currentEpoch.totalShares > 0) {
            currentEpoch.accumulatedRewardPerShare += FixedPointMathLib.mulDiv(msg.value, 1e18, currentEpoch.totalShares);
        }
        
        claimableRewards = true;

        emit RewardsOpened(currentEpochId, msg.value);
    }

    function lockFundsWithdrawAndStartEpoch() external onlyOwner {
        if (currentEpochStatus != EpochStatus.Open) revert WrongPhase("RUN EPOCH: can only start running from open phase");

        currentEpochStatus = EpochStatus.Running;
        claimableRewards = false;
        epochs[currentEpochId].startedAt = uint48(block.timestamp);
        
        // Transfer the total value locked to the multisig wallet
        uint256 amountToTransfer = epochs[currentEpochId].totalValueLocked;
        (bool success,) = fundWallet.call{value: amountToTransfer}("");
        if (!success) revert TransferFailed();

        emit EpochStarted(currentEpochId);
    }

    function getUserStakes(address _user) external view returns (UserStake[] memory) {
        return userStakes[_user];
    }

    function getUserActions(address _user) external view returns (UserAction[] memory) {
        return userActions[_user];
    }

    function getCurrentEpoch() external view returns (Epoch memory) {
        return epochs[currentEpochId];
    }

    function getEpochCount() external view returns (uint256) {
        return epochs.length;
    }

    function getLastClaimEpoch(address _user) public view returns (uint256) {
        UserAction[] memory actions = userActions[_user];
        for (uint i = actions.length; i > 0; i--) {
            if (actions[i-1].actionType == ActionType.Claim) {
                return actions[i-1].epochNumber;
            }
        }
        return 0; // Return 0 if no claims found
    }
}