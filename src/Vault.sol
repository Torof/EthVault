// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/access/Ownable.sol";
import "../lib/solady/src/utils/FixedPointMathLib.sol";

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
 */

contract Vault is Ownable(msg.sender) {
    struct Epoch {
        uint256 totalValueLocked;
        uint256 totalEpochRewards;
    }

    struct UserStake {
        uint256 amount;
        uint256 lastEpochClaimedAt;
    }

    enum EpochStatus {
        Open,
        Running
    }

    EpochStatus public currentEpochStatus;
    address public fundWallet;
    bool public claimableRewards;
    Epoch[] public epochs;
    uint256 public currentEpochId;
    mapping(address => UserStake) public userStakes;
    uint256 public mininmumStake;

    error WrongPhase(string);
    error NoRewardToClaim();
    error UnClaimableRewards();
    error TransferFailed();
    error NoStakeToExit();
    error NotWithdrawable();
    error InsufficientStake(uint256 provided, uint256 required);
    error AmountMustBeGreaterThanZero();
    error InsufficientBalance(uint256 requested, uint256 available);
    error NoActiveStake();
    error InsufficientFundsReturned(uint256 provided, uint256 required);
    error NoRewardsToAllocate();
    error RewardsAlreadyAllocated();

    event EpochOpened(uint256 indexed epochNumber, uint256 timestamp);
    event EpochRunning(uint256 indexed epochNumber, uint256 timestamp, uint256 totalValueLocked);
    event EpochTerminated(uint256 indexed epochNumber, uint256 timestamp);
    event RewardsAllocated(uint256 indexed epochNumber, uint256 rewardAmount);
    event UserDeposit(address indexed user, uint256 amount, uint256 epochNumber);
    event UserWithdraw(address indexed user, uint256 amount, uint256 epochNumber);
    event UserRewardClaim(address indexed user, uint256 amount, uint256 epochNumber);

    constructor(address _fundWallet) {
        // Initialize Epoch 0 as a placeholder that should never be modified
        epochs.push(Epoch(0, 0));

        // Initialize Epoch 1 as the first active epoch
        epochs.push(Epoch(0, 0));

        fundWallet = _fundWallet;
        currentEpochStatus = EpochStatus.Open;
        currentEpochId = 1; // Start with epoch 1

        mininmumStake = 5 ether / 100;

        emit EpochOpened(currentEpochId, block.timestamp);
    }

    function enter() public payable {
        if (currentEpochStatus != EpochStatus.Open) revert WrongPhase("ENTER: only allowed during open phase");
        if (msg.value < mininmumStake) revert InsufficientStake(msg.value, mininmumStake);

        UserStake storage userStake = userStakes[msg.sender];

        if (hasClaimableRewards(msg.sender)) {
            // Claim any pending rewards before adding to the stake
            _claimRewards(msg.sender);
        } else {
            // Initialize lastEpochClaimedAt for new stakes
            userStake.lastEpochClaimedAt = currentEpochId - 1;
        }

        userStake.amount += msg.value;
        epochs[currentEpochId].totalValueLocked += msg.value;

        emit UserDeposit(msg.sender, msg.value, currentEpochId);
    }

    function exit(uint256 _amount) public {
        if (currentEpochStatus != EpochStatus.Open) revert WrongPhase("EXIT: only allowed during open phase");
        UserStake storage userStake = userStakes[msg.sender];
        if (userStake.amount < _amount) revert InsufficientBalance(_amount, userStake.amount);
        if(_amount == 0) revert AmountMustBeGreaterThanZero();

        // Claim rewards before exiting
        if(hasClaimableRewards(msg.sender)) _claimRewards(msg.sender);

        userStake.amount -= _amount;
        epochs[currentEpochId].totalValueLocked -= _amount;

        (bool success,) = msg.sender.call{value: _amount}("");
        if (!success) revert TransferFailed();

        emit UserWithdraw(msg.sender, _amount, currentEpochId);
    }

    function claimRewards() public {
        if (!claimableRewards) revert UnClaimableRewards();
        if (!hasClaimableRewards(msg.sender)) revert NoRewardToClaim();
        _claimRewards(msg.sender);
    }

    function hasClaimableRewards(address _user) public view returns (bool) {
        if(userStakes[_user].amount == 0) return false;
        if(currentEpochId == 1 && !claimableRewards) return false;
        if(currentEpochStatus == EpochStatus.Open && userStakes[_user].lastEpochClaimedAt == currentEpochId - 1) return false;
        if(userStakes[_user].lastEpochClaimedAt == currentEpochId) return false;
        else return true;
    }

    function _claimRewards(address _user) internal {

        UserStake storage userStake = userStakes[_user];

        uint256 totalRewards;
        uint256 startEpoch = userStake.lastEpochClaimedAt + 1;
        uint256 endEpoch;

        // Update the lastEpochClaimedAt for the user
        // If the current epoch is in "open" phase, the user will be able to claim rewards up to the previous epoch only
        if(currentEpochStatus == EpochStatus.Open) {
            endEpoch = currentEpochId - 1;
            userStake.lastEpochClaimedAt = endEpoch;
        } else {
            endEpoch = currentEpochId;
            userStake.lastEpochClaimedAt = endEpoch; 
        }

        //calculate share of user for each epoch
        for (uint256 i = startEpoch; i <= endEpoch; i++) {
            Epoch storage epoch = epochs[i];
            uint256 epochReward = FixedPointMathLib.mulDiv(userStake.amount, epoch.totalEpochRewards, epoch.totalValueLocked);
            totalRewards += epochReward;
        }

        (bool success,) = msg.sender.call{value: totalRewards}("");
        if (!success) revert TransferFailed();

        emit UserRewardClaim(msg.sender, totalRewards, currentEpochId);
    }

    function terminateCurrentAndOpenNextEpoch() external payable onlyOwner {
        if (currentEpochStatus != EpochStatus.Running) revert WrongPhase("END EPOCH: can only end a running epoch");
        if(!claimableRewards) revert WrongPhase("END EPOCH: rewards must be allocated before ending the epoch");
        if (msg.value < epochs[currentEpochId].totalValueLocked) 
            revert InsufficientFundsReturned(msg.value, epochs[currentEpochId].totalValueLocked);

        Epoch storage currentEpoch = epochs[currentEpochId];

        uint256 fundsToTransfer = currentEpoch.totalValueLocked;

        emit EpochTerminated(currentEpochId, block.timestamp);

        // Increment the currentEpochId
        currentEpochId++;

        // Start a new epoch with the current TVL
        epochs.push(Epoch(fundsToTransfer, 0));
        currentEpochStatus = EpochStatus.Open;

        emit EpochOpened(currentEpochId, block.timestamp);
    }

    function allocateRewards() external payable onlyOwner {
        if (currentEpochStatus != EpochStatus.Running) revert WrongPhase("ALLOCATE REWARDS: must be in running phase");
        if (msg.value == 0) revert NoRewardsToAllocate();

        Epoch storage currentEpoch = epochs[currentEpochId];
        if (currentEpoch.totalEpochRewards != 0) revert RewardsAlreadyAllocated();

        currentEpoch.totalEpochRewards = msg.value;

        claimableRewards = true;

        emit RewardsAllocated(currentEpochId, msg.value);
    }

    function lockFundsAndRunCurrentEpoch() external onlyOwner {
        if (currentEpochStatus != EpochStatus.Open) {
            revert WrongPhase("RUN EPOCH: can only start running from open phase");
        }

        currentEpochStatus = EpochStatus.Running;
        claimableRewards = false;

        // Transfer the total value locked to the multisig wallet
        uint256 amountToTransfer = epochs[currentEpochId].totalValueLocked;
        (bool success,) = address(fundWallet).call{value: amountToTransfer}("");
        if (!success) revert TransferFailed();

        emit EpochRunning(currentEpochId, block.timestamp, amountToTransfer);
    }

    function setFundWallet(address _fundWallet) external onlyOwner {
        fundWallet = _fundWallet;
    }

    function setMinimumStake(uint256 _mininmumStake) external onlyOwner {
        mininmumStake = _mininmumStake;
    }

    function getCurrentEpoch() external view returns (Epoch memory) {
        return epochs[currentEpochId];
    }

    function getEpochCount() external view returns (uint256) {
        return epochs.length;
    }

}