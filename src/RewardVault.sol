// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

contract RewardVault {
    uint256 public totalRewards;
    address immutable vault;

    event RewardsReceived(address sender, uint amount);
    event RewardsSent(address receiver, uint amount);

    modifier onlyVault() {
        require(msg.sender == vault, "Unauthorized");
        _;
    }

    constructor(address _vault) {
        vault = _vault;
    }

    function receiveRewards() external payable onlyVault{
        totalRewards += msg.value;
        emit RewardsReceived(msg.sender, msg.value);
    }

    function sendRewards(uint256 _amount, address _receiver) external onlyVault{
        (bool success, ) = vault.call{value: _amount}("");
        require(success, "TransferFailed");
        totalRewards -= _amount;
        emit RewardsSent(_receiver, _amount);
    }
}