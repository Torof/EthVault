//SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import "../src/EthVault.sol";

/**
* @title FailedTransfer
* @notice This contract is used to test failed transfers the Vault contract.
*/

contract FailedTransfer {

    event Received(address sender, uint amount);
    event Fallback(address sender, uint amount, bytes data);

    EthVault public vault = EthVault(0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f);

    receive() external payable {
        emit Received(msg.sender, msg.value);
        revert();
    }

    function enter() public payable {
        vault.enter{value: msg.value}();
    }

    function exit(uint256 _amount) public {
        vault.exit(_amount);
    }

    function claimRewards() public {
        vault.claimRewards();
    }
    
}