// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "solady/utils/FixedPointMathLib.sol";

pragma solidity 0.8.26;

/**
 * @title Ledgity ETH Vault Contract
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
 * @custom:warning claiming entails the use of a loop, if too many epochs to claim, it may fail
 *                 the gas cost of the call and the success or failure should be estimated before calling
 *                 a security function is present to break down claiming in chunks.
 */
contract EthVault is Ownable(msg.sender), ReentrancyGuard {
    /**
     * @dev Struct representing an epoch's data
     * @param totalValueLocked The total value locked in the epoch
     * @param totalEpochRewards The total rewards allocated for the epoch
     */
    struct Epoch {
        uint256 totalValueLocked;
        uint256 totalEpochRewards;
    }

    /**
     * @dev Struct representing a user's stake
     * @param amount The amount staked by the user
     * @param lastEpochClaimedAt The last epoch for which the user claimed rewards
     */
    struct UserStake {
        uint256 amount;
        uint256 lastEpochClaimedAt;
    }

    /**
     * @dev Enum representing the status of an epoch
     */
    enum EpochStatus {
        Open,
        Running
    }

    /// @notice The current status of the epoch
    EpochStatus public currentEpochStatus;
    /// @notice The address where funds are transferred during epoch execution
    address public fundWallet;
    /// @notice Indicates if rewards are currently claimable
    bool public claimableRewards;
    /// @notice Array of all epochs
    Epoch[] public epochs;
    /// @notice The ID of the current epoch
    uint256 public currentEpochId;
    /// @notice Mapping of user addresses to their stakes
    mapping(address => UserStake) public userStakes;
    /// @notice The minimum stake amount required
    uint256 public mininmumStake;

    bool public locked;

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
    error ContractLocked();
    error InsufficientClaimableEpochs(uint256 requestedEpochs, uint256 availableEpochs);
    error InvalidEpochsToClaim(uint256 requestedEpochs);

    event EpochOpened(uint256 indexed epochNumber, uint256 timestamp);
    event EpochRunning(uint256 indexed epochNumber, uint256 timestamp, uint256 totalValueLocked);
    event EpochTerminated(uint256 indexed epochNumber, uint256 timestamp);
    event RewardsAllocated(uint256 indexed epochNumber, uint256 rewardAmount);
    event UserDeposit(address indexed user, uint256 amount, uint256 epochNumber);
    event UserWithdraw(address indexed user, uint256 amount, uint256 epochNumber);
    event UserRewardClaim(address indexed user, uint256 amount, uint256 epochNumber);
    event MinimumStakeChanged(uint256 oldMinimumStake, uint256 newMinimumStake);
    event FundWalletChanged(address oldFundWallet, address newFundWallet);
    event FundsTransferredToFundWallet(uint256 amount, uint256 indexed epochId);
    event RewardsClaimabilityChanged(bool claimable);
    event LockingContract(bool locked);

    /**
     * @notice Initializes the Vault contract
     * @param _fundWallet The address where funds will be transferred during epoch execution
     */
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

    modifier IsLocked() {
        if (locked) revert ContractLocked();
        _;
    }

    /**
     * @notice Allows a user to enter the vault by staking ETH
     * @dev This function can only be called when the epoch status is Open
     */
    function enter() public payable nonReentrant IsLocked {
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

    /**
     * @notice Allows a user to exit the vault by unstaking ETH
     * @param _amount The amount of ETH to unstake
     * @dev This function can only be called when the epoch status is Open
     */
    function exit(uint256 _amount) public nonReentrant IsLocked {
        if (currentEpochStatus != EpochStatus.Open) revert WrongPhase("EXIT: only allowed during open phase");
        UserStake storage userStake = userStakes[msg.sender];
        if (userStake.amount < _amount) revert InsufficientBalance(_amount, userStake.amount);
        if (_amount == 0) revert AmountMustBeGreaterThanZero();

        // Claim rewards before exiting
        if (hasClaimableRewards(msg.sender)) _claimRewards(msg.sender);

        userStake.amount -= _amount;
        epochs[currentEpochId].totalValueLocked -= _amount;

        (bool success,) = msg.sender.call{value: _amount}("");
        if (!success) revert TransferFailed();

        emit UserWithdraw(msg.sender, _amount, currentEpochId);
    }

    /**
     * @notice Allows a user to claim their rewards
     * @dev This function can be called at any time, except when rewards are not claimable
     */
    function claimRewards() public IsLocked {
        if (!claimableRewards) revert UnClaimableRewards();
        if (!hasClaimableRewards(msg.sender)) revert NoRewardToClaim();
        _claimRewards(msg.sender);
    }

    /**
     * @notice Checks if a user has claimable rewards
     * @param _user The address of the user to check
     * @return bool indicating whether the user has claimable rewards
     */
    function hasClaimableRewards(address _user) public view returns (bool) {
        if (userStakes[_user].amount == 0) return false;
        if (currentEpochId == 1 && !claimableRewards) return false;
        if (currentEpochStatus == EpochStatus.Open && userStakes[_user].lastEpochClaimedAt == currentEpochId - 1) {
            return false;
        }
        if (userStakes[_user].lastEpochClaimedAt == currentEpochId) return false;
        else return true;
    }

    /**
     * @dev Internal function to process reward claiming
     * @param _user The address of the user claiming rewards
     */
    function _claimRewards(address _user) internal {
        UserStake storage userStake = userStakes[_user];

        uint256 totalRewards;
        uint256 startEpoch = userStake.lastEpochClaimedAt + 1;
        uint256 endEpoch;

        // Update the lastEpochClaimedAt for the user
        // If the current epoch is in "open" phase, the user will be able to claim rewards up to the previous epoch only
        if (currentEpochStatus == EpochStatus.Open) {
            endEpoch = currentEpochId - 1;
            userStake.lastEpochClaimedAt = endEpoch;
        } else {
            endEpoch = currentEpochId;
            userStake.lastEpochClaimedAt = endEpoch;
        }

        //calculate share of user for each epoch
        for (uint256 i = startEpoch; i <= endEpoch; i++) {
            Epoch storage epoch = epochs[i];
            uint256 epochReward =
                FixedPointMathLib.mulDiv(userStake.amount, epoch.totalEpochRewards, epoch.totalValueLocked);
            totalRewards += epochReward;
        }

        (bool success,) = msg.sender.call{value: totalRewards}("");
        if (!success) revert TransferFailed();

        emit UserRewardClaim(msg.sender, totalRewards, currentEpochId);
    }

    /**
     * @notice Allows a user to claim rewards for a specific number of epochs
     * @param _numberOfEpochs The number of epochs to claim rewards for
     * @dev This function can be called at any time, except when rewards are not claimable
     */
    function claimRewardsForEpochs(uint256 _numberOfEpochs) public {
    if (_numberOfEpochs == 0) revert InvalidEpochsToClaim(_numberOfEpochs);
    if (!claimableRewards) revert UnClaimableRewards();
    if (!hasClaimableRewards(msg.sender)) revert NoRewardToClaim();
    
    UserStake storage userStake = userStakes[msg.sender];
    uint256 startEpoch = userStake.lastEpochClaimedAt + 1;
    uint256 maxClaimableEpoch = currentEpochStatus == EpochStatus.Open ? currentEpochId - 1 : currentEpochId;
    uint256 availableEpochs = maxClaimableEpoch >= startEpoch ? maxClaimableEpoch - startEpoch + 1 : 0;
    
    if (_numberOfEpochs > availableEpochs) {
        revert InsufficientClaimableEpochs(_numberOfEpochs, availableEpochs);
    }
    
    uint256 endEpoch = startEpoch + _numberOfEpochs - 1;
    uint256 totalRewards;

    for (uint256 i = startEpoch; i <= endEpoch; i++) {
        Epoch storage epoch = epochs[i];
        uint256 epochReward = FixedPointMathLib.mulDiv(userStake.amount, epoch.totalEpochRewards, epoch.totalValueLocked);
        totalRewards += epochReward;
    }

    userStake.lastEpochClaimedAt = endEpoch;

    (bool success,) = msg.sender.call{value: totalRewards}("");
    if (!success) revert TransferFailed();

    emit UserRewardClaim(msg.sender, totalRewards, endEpoch);
}

    /**
     * @notice Terminates the current epoch and opens the next one
     * @dev This function can only be called by the contract owner
     */
    function terminateCurrentAndOpenNextEpoch() external payable onlyOwner {
        if (currentEpochStatus != EpochStatus.Running) revert WrongPhase("END EPOCH: can only end a running epoch");
        if (!claimableRewards) revert WrongPhase("END EPOCH: rewards must be allocated before ending the epoch");
        uint256 requiredFunds = epochs[currentEpochId].totalValueLocked;
        if (msg.value < requiredFunds) {
            revert InsufficientFundsReturned(msg.value, requiredFunds);
        }

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

    /**
     * @notice Allocates rewards for the current epoch
     * @dev This function can only be called by the contract owner when the epoch is Running
     */
    function allocateRewards() external payable onlyOwner {
        if (currentEpochStatus != EpochStatus.Running) revert WrongPhase("ALLOCATE REWARDS: must be in running phase");
        if (msg.value == 0) revert NoRewardsToAllocate();

        Epoch storage currentEpoch = epochs[currentEpochId];
        if (currentEpoch.totalEpochRewards != 0) revert RewardsAlreadyAllocated();

        //assign the rewards
        currentEpoch.totalEpochRewards = msg.value;

        // users can now claim all rewards
        claimableRewards = true;

        emit RewardsAllocated(currentEpochId, msg.value);
        emit RewardsClaimabilityChanged(true);
    }

    /**
     * @notice Locks funds and starts running the current epoch
     * @dev This function can only be called by the contract owner when the epoch is Open
     */
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
        emit FundsTransferredToFundWallet(amountToTransfer, currentEpochId);
    }

    /**
     * @notice Calculates the number of Epochs a user has been staking for
     * @param _user The address of the user to check
     * @return uint256 representing the number of epochs the user has been staking for
     */
    function getEpochLengthToClaim(address _user) external view returns (uint256) {
        if (userStakes[_user].amount == 0) {
            return 0; // Return 0 for users with no stake
        }

        uint256 length;
        uint256 startEpoch = userStakes[_user].lastEpochClaimedAt + 1;
        uint256 endEpoch;

        if (currentEpochStatus == EpochStatus.Open) {
            endEpoch = currentEpochId - 1;
        } else {
            endEpoch = currentEpochId;
        }

        for (uint256 i = startEpoch; i <= endEpoch; i++) {
            length++;
        }

        return length;
    }

    /**
     * @notice Sets a new fund wallet address
     * @param _fundWallet The new fund wallet address
     * @dev This function can only be called by the contract owner
     */
    function setFundWallet(address _fundWallet) external onlyOwner {
        address previousFundWallet = fundWallet;
        fundWallet = _fundWallet;
        emit FundWalletChanged(previousFundWallet, fundWallet);
    }

    /**
     * @notice Sets a new minimum stake amount
     * @param _mininmumStake The new minimum stake amount
     * @dev This function can only be called by the contract owner
     */
    function setMinimumStake(uint256 _mininmumStake) external onlyOwner {
        uint256 previousMininmumStake = mininmumStake;
        mininmumStake = _mininmumStake;
        emit MinimumStakeChanged(previousMininmumStake, mininmumStake);
    }

    /**
     * @notice Retrieves the current epoch data
     * @return Epoch struct containing the current epoch's data
     */
    function getCurrentEpoch() external view returns (Epoch memory) {
        return epochs[currentEpochId];
    }

    /**
     * @notice Retrieves the total number of epochs
     * @return uint256 representing the total number of epochs
     */
    function getEpochCount() external view returns (uint256) {
        return epochs.length;
    }

    function lockOrUnlockContract(bool _locked) external onlyOwner {
        require(locked != _locked, "Contract already in requested state");
        locked = _locked;
        emit LockingContract(locked);
    }
}
