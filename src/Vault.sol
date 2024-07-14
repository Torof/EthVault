// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

contract Vault {
    struct Epoch {
        uint48 startTime;
        uint48 endTime;
        uint48 rewardPercentage;
        uint256 totalValueLocked;
    }

    struct UserStake {
        uint256 epochIn;
        uint256 epochOut;
        uint256 stake;
    }

    bool locked;
    Epoch[] public epochs;
    mapping( address => UserStake[] ) public userStakes;

    error IsLocked(string);
    error IsUnlocked();
    error TransferFailed();

    constructor() {
        epochs.push(Epoch(0,0,0,0));
    }

    function enter() public payable {
        if(locked) revert IsLocked("");
        uint256 currentEpoch = epochs.length;
        UserStake memory stake = UserStake(currentEpoch, 0, msg.value);
        userStakes[msg.sender].push(stake);
    }

    function exit() public {
        if(locked) revert IsLocked("");
        
        UserStake memory currentStake = userStakes[msg.sender][userStakes[msg.sender].length - 1];
        currentStake.epochOut = epochs.length;
        (bool success,) = msg.sender.call{value: currentStake.stake}("");
        if(!success) revert TransferFailed();
    }

    function claimRewards() public {
        uint256 rewards;
        (bool success,) = msg.sender.call{value: rewards}("");
        if(!success) revert TransferFailed();
    }

    function startNewEpoch(uint48 _duration, uint48 _rewardPercentage) external  {
    // Implement logic to start a new epoch
}

function endCurrentEpoch() external  {
    // Implement logic to end the current epoch
}

function withdrawForInvestment(uint256 _amount) external  {
    // Implement logic to withdraw funds for real-world investments
}

function depositRewards() external payable  {
    // Implement logic to deposit rewards
}

}

