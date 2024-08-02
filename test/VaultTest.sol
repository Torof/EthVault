// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/Vault.sol";
import "./FailedTransfer.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract VaultTest is Test {
    Vault public vault;
    FailedTransfer public failedTransfer;
    address public owner;
    address public fundWallet;
    address public user1;
    address public user2;
    address public failedT;

    function setUp() public {
        owner = address(this);
        fundWallet = vm.addr(1);
        user1 = vm.addr(2);
        user2 = vm.addr(3);
        failedT = vm.addr(4);
        vm.deal(owner, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(failedT, 100 ether);
        vault = new Vault(fundWallet);
        failedTransfer = new FailedTransfer();
    }

    // --------------------------------------
    //     INITIAL STATE AND SETUP TESTS
    // --------------------------------------

    function testInitialState() public {
        assertEq(vault.currentEpochId(), 1);
        assertEq(uint256(vault.currentEpochStatus()), uint256(Vault.EpochStatus.Open));
        assertEq(vault.claimableRewards(), false);
    }

    function testInitialMinimumStake() public {
        assertEq(vault.mininmumStake(), 0.05 ether);
    }

    function testSetMinimumStake() public {
        uint256 newMinimumStake = 0.1 ether;

        // Ensure only the owner can call this function
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        vm.prank(user1);
        vault.setMinimumStake(newMinimumStake);

        // Test that we can enter with the new minimum stake
        vm.prank(user1);
        vault.enter{value: 0.1 ether}();
        (uint256 amount,) = vault.userStakes(user1);
        assertEq(amount, 0.1 ether);
    }

    function testSetFundWallet() public {
        address newFundWallet = vm.addr(4);

        // Set the new fund wallet as the owner
        vm.prank(owner);
        vault.setFundWallet(newFundWallet);

        // Verify the new fund wallet
        assertEq(vault.fundWallet(), newFundWallet);
    }

    function testErrorSetFundWalletUnauthorized() public {
        // Ensure only the owner can call this function
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector, 0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF
            )
        );
        vm.prank(user1);
        vault.setFundWallet(user1);
    }

    // --------------------------------------
    //       ENTER (STAKING) TESTS
    // --------------------------------------

    function testErrorEnterBelowMinimumStake() public {
        //reverts on enter below minimum stake
        vm.expectRevert(abi.encodeWithSelector(Vault.InsufficientStake.selector, 0.04 ether, 0.05 ether));
        vm.prank(user1);
        vault.enter{value: 0.04 ether}();
    }

    function testEnterWithMinimumStake() public {
        vm.prank(user1);
        vault.enter{value: 0.05 ether}();

        (uint256 amount,) = vault.userStakes(user1);
        assertEq(amount, 0.05 ether);
    }

    function testEnterFirstEpoch() public {
        uint256 depositAmountU1 = 1 ether;
        uint256 depositAmountU2 = 3 ether;
        vm.prank(user1);
        vault.enter{value: depositAmountU1}();

        vm.prank(user2);
        vault.enter{value: depositAmountU2}();

        //verify user1 stakes
        (uint256 amountU1, uint256 lastEpochClaimedAtU1) = vault.userStakes(user1);
        assertEq(amountU1, depositAmountU1);
        assertEq(lastEpochClaimedAtU1, 0);

        // verify user2 stakes
        (uint256 amountU2, uint256 lastEpochClaimedAtU2) = vault.userStakes(user2);
        assertEq(amountU2, depositAmountU2);
        assertEq(lastEpochClaimedAtU2, 0);

        // for 1st epoch, TVL is the total of all deposits
        Vault.Epoch memory currentEpoch = vault.getCurrentEpoch();
        assertEq(currentEpoch.totalValueLocked, depositAmountU1 + depositAmountU2);
    }

    function testEnterWithExistingStake() public {
        vm.startPrank(user1);
        vault.enter{value: 1 ether}();

        // Simulate an epoch cycle
        vm.stopPrank();
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        // Allocate rewards
        vm.prank(owner);
        vault.allocateRewards{value: 0.1 ether}();

        // Terminate current epoch and open next
        vm.prank(owner);
        vault.terminateCurrentAndOpenNextEpoch{value: 1 ether}();

        // Enter again with existing stake
        vm.prank(user1);
        vault.enter{value: 2 ether}();

        (uint256 amount, uint256 lastEpochClaimedAt) = vault.userStakes(user1);
        assertEq(amount, 3 ether);
        assertEq(lastEpochClaimedAt, 1);
    }

    function testMultipleUsersStaking() public {
        uint256 user1Deposit = 1 ether;
        uint256 user2Deposit = 2 ether;

        vm.prank(user1);
        vault.enter{value: user1Deposit}();
        vm.prank(user2);
        vault.enter{value: user2Deposit}();

        Vault.Epoch memory currentEpoch = vault.getCurrentEpoch();
        assertEq(currentEpoch.totalValueLocked, user1Deposit + user2Deposit);
    }

    function testEnterWithZeroValue() public {
        //reverts on enter with 0
        vm.expectRevert(abi.encodeWithSelector(Vault.InsufficientStake.selector, 0, 0.05 ether));
        vm.prank(user1);
        vault.enter{value: 0}();
    }

    function testErrorEnterDuringRunningEpoch() public {
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        vm.expectRevert(abi.encodeWithSelector(Vault.WrongPhase.selector, "ENTER: only allowed during open phase"));
        vm.prank(user1);
        vault.enter{value: 1 ether}();
    }

    // -------------------------
    //  EPOCH MANAGEMENT TESTS
    // -------------------------

    function testLockFundsAndRunCurrentEpoch() public {
        uint256 depositAmount = 1 ether;
        vm.prank(user1);
        vault.enter{value: depositAmount}();

        //owner start running epoch, funds are locked
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        assertEq(uint256(vault.currentEpochStatus()), uint256(Vault.EpochStatus.Running));
        assertEq(vault.claimableRewards(), false);
        assertEq(fundWallet.balance, depositAmount);

        //TODO verify cannot enter, exit and claim
    }

    function testErrorRunAlreadyRunningEpoch() public {
        //owner starts running epoch and funds are locked
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        //reverts on running already running epoch
        vm.expectRevert(
            abi.encodeWithSelector(Vault.WrongPhase.selector, "RUN EPOCH: can only start running from open phase")
        );
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();
    }

    function testErrorterminateCurrentAndOpenNextEpochNotRunning() public {
        //reverts on terminating epoch not in running phase
        vm.expectRevert(abi.encodeWithSelector(Vault.WrongPhase.selector, "END EPOCH: can only end a running epoch"));
        vm.prank(owner);
        vault.terminateCurrentAndOpenNextEpoch{value: 1 ether}();
    }

    function testTerminateCurrentAndOpenNextEpoch() public {
        uint256 depositAmount = 1 ether;
        uint256 rewardAmount = 0.1 ether;

        //a user enters
        vm.prank(user1);
        vault.enter{value: depositAmount}();

        //owner starts running epoch and funds are locked
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        //owner allocates rewards
        vm.prank(owner);
        vault.allocateRewards{value: rewardAmount}();

        //owner terminates current epoch and open next
        vm.prank(owner);
        vault.terminateCurrentAndOpenNextEpoch{value: vault.getCurrentEpoch().totalValueLocked}();

        //verify next epoch is open
        assertEq(vault.currentEpochId(), 2);
        assertEq(uint256(vault.currentEpochStatus()), uint256(Vault.EpochStatus.Open));
    }

    function testErrorTerminateCurrentAndOpenNextEpochInsufficientFundsReturned() public {
        vm.prank(user1);
        vault.enter{value: 1 ether}();

        //owner starts running epoch and funds are locked
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        //owner allocates rewards
        vm.prank(owner);
        vault.allocateRewards{value: 0.1 ether}();

        // The full TVL should be returned to the contract
        vm.expectRevert(
            abi.encodeWithSelector(Vault.InsufficientFundsReturned.selector, 900000000000000000, 1000000000000000000)
        );
        vm.prank(owner);
        vault.terminateCurrentAndOpenNextEpoch{value: 0.9 ether}();
    }

    function testTransitionToNextEpoch() public {
        uint256 depositAmount = 1 ether;

        //a user enters
        vm.prank(user1);
        vault.enter{value: depositAmount}();

        //owner starts running epoch and funds are locked
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        //owner allocates rewards
        vm.prank(owner);
        vault.allocateRewards{value: 0.1 ether}();

        //owner terminates current epoch and open next
        vm.prank(owner);
        vault.terminateCurrentAndOpenNextEpoch{value: vault.getCurrentEpoch().totalValueLocked}();

        //verify next epoch is open
        assertEq(vault.currentEpochId(), 2);
        assertEq(uint256(vault.currentEpochStatus()), uint256(Vault.EpochStatus.Open));
    }

    function testErrorTransitionToNextEpochRewardsNotAllocated() public {
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        vm.expectRevert(
            abi.encodeWithSelector(
                Vault.WrongPhase.selector, "END EPOCH: rewards must be allocated before ending the epoch"
            )
        );
        vm.prank(owner);
        vault.terminateCurrentAndOpenNextEpoch{value: 1 ether}();
    }

    function testGetCurrentEpoch() public {
        vm.prank(user1);
        vault.enter{value: 1 ether}();

        Vault.Epoch memory currentEpoch = vault.getCurrentEpoch();
        assertEq(currentEpoch.totalValueLocked, 1 ether);
        assertEq(currentEpoch.totalEpochRewards, 0);
    }

    function testGetEpochCount() public {
        uint256 initialCount = vault.getEpochCount();
        assertEq(initialCount, 2); // Initial state should have 2 epochs (0 and 1)

        // Run through a full epoch cycle
        vm.prank(user1);
        vault.enter{value: 1 ether}();
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();
        vm.prank(owner);
        vault.allocateRewards{value: 0.1 ether}();
        vm.prank(owner);
        vault.terminateCurrentAndOpenNextEpoch{value: 1 ether}();

        uint256 newCount = vault.getEpochCount();
        assertEq(newCount, 3); // Should now have 3 epochs
    }

    function testGetCurrentEpochStatus() public {
        (Vault.EpochStatus status) = vault.currentEpochStatus();
        assertEq(uint256(status), uint256(Vault.EpochStatus.Open));

        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();
        (status) = vault.currentEpochStatus();
        assertEq(uint256(status), uint256(Vault.EpochStatus.Running));

        vm.prank(owner);
    }

    

    // --------------------------------------
    //    ALLOCATE REWARDS TESTS
    // --------------------------------------

    function testAllocateRewards() public {
        uint256 depositAmount = 1 ether;
        uint256 rewardAmount = 0.1 ether;

        //a user enters
        vm.prank(user1);
        vault.enter{value: depositAmount}();

        //owner starts running epoch and funds are locked
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        //owner allocates rewards
        vm.prank(owner);
        vault.allocateRewards{value: rewardAmount}();

        //verify rewards are allocated and and claimable
        assertEq(vault.claimableRewards(), true);
        Vault.Epoch memory currentEpoch = vault.getCurrentEpoch();
        assertEq(currentEpoch.totalEpochRewards, rewardAmount);
    }

    function testErrorAllocateRewardsInOpenPhase() public {
        vm.prank(owner);
        (Vault.EpochStatus status) = vault.currentEpochStatus();
        assertEq(uint256(status), uint256(Vault.EpochStatus.Open));
        vm.expectRevert(abi.encodeWithSelector(Vault.WrongPhase.selector, "ALLOCATE REWARDS: must be in running phase"));
        vault.allocateRewards{value: 0.1 ether}();
    }

    function testErrorDoubleAllocateRewards() public {
        //owner starts running epoch and funds are locked
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        //owner allocates rewards
        vm.prank(owner);
        vault.allocateRewards{value: 0.1 ether}();

        //verify rewards are allocated and and claimable
        (Vault.Epoch memory epoch) = vault.getCurrentEpoch();
        assertEq(epoch.totalEpochRewards, 0.1 ether);
        assertEq(vault.claimableRewards(), true);

        //reverts on allocating rewards again
        vm.expectRevert(abi.encodeWithSelector(Vault.RewardsAlreadyAllocated.selector));
        vm.prank(owner);
        vault.allocateRewards{value: 0.1 ether}();
    }

    function testAllocateZeroRewards() public {
        //owner starts running epoch and funds are locked
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        //owner allocates 0 rewards, must revert
        vm.expectRevert(Vault.NoRewardsToAllocate.selector);
        vm.prank(owner);
        vault.allocateRewards{value: 0}();
    }

    // --------------------------------------
    //  EXIT (UNSTAKING) TESTS
    // --------------------------------------

    function testExit() public {
        uint256 depositAmount = 10 ether;
        uint256 rewardAmount = 1 ether;

        //user1 enters the vault
        vm.startPrank(user1);
        vault.enter{value: depositAmount}();
        vm.stopPrank();

        //epoch starts running and funds are locked
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        //owner allocates rewards
        vm.prank(owner);
        vault.allocateRewards{value: rewardAmount}();

        //terminate current epoch
        vm.prank(owner);
        vault.terminateCurrentAndOpenNextEpoch{value: vault.getCurrentEpoch().totalValueLocked}();

        vm.startPrank(user1);
        uint256 balanceBefore = user1.balance;
        vault.exit(depositAmount);
        uint256 balanceAfter = user1.balance;
        vm.stopPrank();

        assertEq(balanceAfter - balanceBefore, depositAmount + rewardAmount);

        (uint256 amount,) = vault.userStakes(user1);
        assertEq(amount, 0);
    }

    function testErrorExitMoreThanStaked() public {
        uint256 depositAmount = 1 ether;
        uint256 rewardAmount = 0.1 ether;
        vm.startPrank(user1);
        vault.enter{value: depositAmount}();
        vm.stopPrank();

        // Lock funds and allocate rewards
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        vm.prank(owner);
        vault.allocateRewards{value: rewardAmount}();

        // Transition to next epoch
        vm.prank(owner);
        vault.terminateCurrentAndOpenNextEpoch{value: vault.getCurrentEpoch().totalValueLocked}();

        // Try to exit with more than staked + rewards
        vm.expectRevert(
            abi.encodeWithSelector(Vault.InsufficientBalance.selector, depositAmount + 100 wei, depositAmount)
        );
        vm.prank(user1);
        vault.exit(depositAmount + 100 wei);
    }

    function testErrorExitDuringRunningEpoch() public {
        //user enters
        vm.prank(user1);
        vault.enter{value: 1 ether}();

        //owner starts running epoch and funds are locked
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        //reverts on exit during running epoch
        vm.expectRevert(abi.encodeWithSelector(Vault.WrongPhase.selector, "EXIT: only allowed during open phase"));
        vm.prank(user1);
        vault.exit(1 ether);
    }

    function testExitWithZeroValue() public {
        //user enters
        vm.prank(user1);
        vault.enter{value: 1 ether}();

        //reverts on exit with 0
        vm.expectRevert(Vault.AmountMustBeGreaterThanZero.selector);
        vm.prank(user1);
        vault.exit(0);
    }

    function testErrorNoStakeToExit() public {
        vm.expectRevert(abi.encodeWithSelector(Vault.InsufficientBalance.selector, 1 ether, 0));
        vm.prank(user1);
        vault.exit(1 ether);
    }

    // --------------------------------------
    //  CLAIM REWARDS TESTS
    // --------------------------------------

    //TODO test entering an epoch after 1st. TVL should be previous tvl + or - enter and exits since opening

    function testClaimRewards() public {
        uint256 depositAmount = 1 ether;
        uint256 rewardAmount = 0.1 ether;

        //a user enters
        vm.prank(user1);
        vault.enter{value: depositAmount}();

        //owner starts running epoch and funds are locked
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        //owner allocates rewards
        vm.prank(owner);
        vault.allocateRewards{value: rewardAmount}();

        //user claims rewards after allocation
        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        vault.claimRewards();
        uint256 balanceAfter = user1.balance;

        //verify succesful claim
        assertEq(balanceAfter - balanceBefore, rewardAmount);
    }

    function testClaimRewardsMultipleEpochs() public {
        vm.prank(user1);
        vault.enter{value: 1 ether}();

        //   ---- First epoch ----
        vm.prank(owner);
        //owner starts running epoch and funds are locked
        vault.lockFundsAndRunCurrentEpoch();
        vm.prank(owner);
        //owner allocates rewards
        vault.allocateRewards{value: 0.1 ether}();
        vm.prank(owner);
        //owner terminates current epoch and open next
        vault.terminateCurrentAndOpenNextEpoch{value: 1 ether}();

        //   ---- Second epoch ----
        vm.prank(owner);
        //owner starts running epoch and funds are locked
        vault.lockFundsAndRunCurrentEpoch();
        vm.prank(owner);
        //owner allocates rewards
        vault.allocateRewards{value: 0.2 ether}();
        vm.prank(owner);
        //owner terminates current epoch and open next
        vault.terminateCurrentAndOpenNextEpoch{value: 1 ether}();

        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        vault.claimRewards();
        uint256 balanceAfter = user1.balance;

        assertEq(balanceAfter - balanceBefore, 0.3 ether); // Total rewards from both epochs
    }

    function testErrorClaimNoActiveStakeBeforeEntrance() public {
        //owner starts running epoch and funds are locked
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        //owner allocates rewards
        vm.prank(owner);
        vault.allocateRewards{value: 0.1 ether}();

        //reverts on claiming rewards with no active stake
        vm.expectRevert(Vault.NoRewardToClaim.selector);
        vm.prank(user2);
        vault.claimRewards();
    }

    function testErrorClaimNoActiveStakeAfterFullExit() public {
        vm.prank(user1);
        vault.enter{value: 1 ether}();

        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        vm.prank(owner);
        vault.allocateRewards{value: 0.1 ether}();

        vm.prank(owner);
        vault.terminateCurrentAndOpenNextEpoch{value: 1 ether}();

        vm.prank(user1);
        vault.exit(1 ether);

        vm.expectRevert(Vault.NoRewardToClaim.selector);
        vm.prank(user1);
        vault.claimRewards();
    }

    function testErrorClaimNoActiveStakeAfterClaimingAgainSameEpoch() public {
        //user enters
        vm.prank(user1);
        vault.enter{value: 1 ether}();

        //owner starts running epoch and funds are locked
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        //owner allocates rewards
        vm.prank(owner);
        vault.allocateRewards{value: 0.1 ether}();

        vm.prank(user1);
        vault.claimRewards();

        //claim again same epoch, no reward to claim
        vm.expectRevert(Vault.NoRewardToClaim.selector);
        vm.prank(user1);
        vault.claimRewards();
    }

    function testErrorClaimNoActiveStakeAfterExit() public {
        vm.prank(user1);
        vault.enter{value: 1 ether}();

        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        vm.prank(owner);
        vault.allocateRewards{value: 0.1 ether}();

        vm.prank(owner);
        vault.terminateCurrentAndOpenNextEpoch{value: 1 ether}();

        vm.prank(user1);
        vault.exit(1 ether);

        //user has exited and claimed automatically, no reward to claim
        vm.expectRevert(abi.encodeWithSelector(Vault.NoRewardToClaim.selector));
        vm.prank(user1);
        vault.claimRewards();
    }

    function testErrorClaimUnclaimable() public {
        //user enters
        vm.prank(user1);
        vault.enter{value: 1 ether}();

        //owner starts running epoch and funds are locked
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        //reverts on claiming rewards before allocation
        vm.expectRevert(abi.encodeWithSelector(Vault.UnClaimableRewards.selector));
        vm.prank(user1);
        vault.claimRewards();
    }

    function testMultipleUsersInteractionClaim() public {
        vm.prank(user1);
        vault.enter{value: 1 ether}();

        vm.prank(user2);
        vault.enter{value: 2 ether}();

        //start running epoch and lock funds
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        //allocate rewards
        vm.prank(owner);
        vault.allocateRewards{value: 0.3 ether}();

        //terminate current epoch and open next
        vm.prank(owner);
        vault.terminateCurrentAndOpenNextEpoch{value: 3 ether}();

        vm.prank(user1);
        uint256 user1BalanceBefore = user1.balance;
        vault.claimRewards();
        uint256 user1BalanceAfter = user1.balance;

        vm.prank(user2);
        uint256 user2BalanceBefore = user2.balance;
        vault.exit(2 ether);
        uint256 user2BalanceAfter = user2.balance;

        // Check user1's claimed rewards
        assertEq(user1BalanceAfter - user1BalanceBefore, 0.1 ether);

        // Check user2's exit amount (stake + rewards)
        assertEq(user2BalanceAfter - user2BalanceBefore, 2.2 ether);

        // Check final state
        (uint256 user1Stake,) = vault.userStakes(user1);
        (uint256 user2Stake,) = vault.userStakes(user2);
        assertEq(user1Stake, 1 ether);
        assertEq(user2Stake, 0);
        Vault.Epoch memory currentEpoch = vault.getCurrentEpoch();
        assertEq(currentEpoch.totalValueLocked, 1 ether);
    }

    function testClaimRewardsInRunningEpoch() public {
        vm.prank(user1);
        vault.enter{value: 1 ether}();

        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        vm.prank(owner);
        vault.allocateRewards{value: 0.1 ether}();

        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        vault.claimRewards();
        uint256 balanceAfter = user1.balance;

        assertEq(balanceAfter - balanceBefore, 0.1 ether);
    }

    function testClaimRewardsInOpenEpoch() public {
        vm.prank(user1);
        vault.enter{value: 1 ether}();

        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        vm.prank(owner);
        vault.allocateRewards{value: 0.1 ether}();

        vm.prank(owner);
        vault.terminateCurrentAndOpenNextEpoch{value: 1 ether}();

        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        vault.claimRewards();
        uint256 balanceAfter = user1.balance;

        assertEq(balanceAfter - balanceBefore, 0.1 ether);
    }

    function testHasClaimableRewards() public {
        // No stake
        assertFalse(vault.hasClaimableRewards(user1));

        // First epoch, no rewards allocated
        vm.prank(user1);
        vault.enter{value: 1 ether}();
        assertFalse(vault.hasClaimableRewards(user1));

        // Rewards allocated
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();
        vm.prank(owner);
        vault.allocateRewards{value: 0.1 ether}();
        assertTrue(vault.hasClaimableRewards(user1));

        // After claiming in open epoch
        vm.prank(owner);
        vault.terminateCurrentAndOpenNextEpoch{value: 1 ether}();
        vm.prank(user1);
        vault.claimRewards();
        assertFalse(vault.hasClaimableRewards(user1));
    }

    function testAddress() public {
        assertEq(address(vault), 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f);
    }

    function testErrorExitTransferFailed() public {
        vm.prank(failedT);
        failedTransfer.enter{value: 1 ether}();

        vm.expectRevert(abi.encodeWithSelector(Vault.TransferFailed.selector));
        vm.prank(failedT);
        failedTransfer.exit(1 ether);
    }

    function testErrorClaimTransferFailed() public {
        vm.prank(failedT);
        failedTransfer.enter{value: 1 ether}();

        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        vm.prank(owner);
        vault.allocateRewards{value: 0.1 ether}();

        vm.expectRevert(abi.encodeWithSelector(Vault.TransferFailed.selector));
        vm.prank(failedT);
        failedTransfer.claimRewards();
    }

    function testErrorLockFundsAndRunCurrentEpochTransferFailed() public {
        vm.prank(owner);
        vault.setFundWallet(address(failedTransfer));

        //fundwallet is address that will revert on transfer
        address fw = vault.fundWallet();
        assertEq(fw, address(failedTransfer));

        //user enters
        vm.prank(user1);
        vault.enter{value: 1 ether}();

        //vault has balance
        assertEq((address(vault)).balance, 1 ether);

        //will revert because fundwallet reverts on receiving funds
        vm.expectRevert(abi.encodeWithSelector(Vault.TransferFailed.selector));
        vm.prank(owner);
        vault.lockFundsAndRunCurrentEpoch();

        //transfer failed, vault still has balance
        assertEq((address(vault)).balance,  1 ether);
    }
}
