// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {DeployRaffle} from "script/DeployRaffle.s.sol";
import {Raffle} from "src/Raffle.sol";
import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {VRFCoordinatorV2Mock} from "chainlink-brownie-contracts/contracts/src/v0.8/mocks/VRFCoordinatorV2Mock.sol";

contract RaffleTest is Test {
    /**
     * Events
     */
    event EnteredRaffle(address indexed player);
    event PausedRaffle(address indexed owner, Raffle.RaffleState indexed raffleState);
    event RefundedRaffle(address payable[] indexed refundedPlayers, uint256 amount);
    event ResumedRaffle(address indexed owner, Raffle.RaffleState indexed raffleState);

    Raffle raffle;
    HelperConfig helperConfig;

    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint32 callbackGasLimit;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARING_USER_BALANCE = 10 ether;

    function setUp() external {
        DeployRaffle deployer = new DeployRaffle();
        (raffle, helperConfig) = deployer.run();

        vm.deal(PLAYER, STARING_USER_BALANCE);

        (entranceFee, interval, vrfCoordinator, gasLane,, callbackGasLimit,,) = helperConfig.activeNetworkConfig();
    }

    function testRaffleInitializesInOpenState() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    /////////////////////////
    // owner actions       //
    /////////////////////////

    function testPauseRaffleRevertsWhenNotOwner() public {
        vm.expectRevert(Raffle.Raffle__NotOwner.selector);
        vm.prank(PLAYER);
        raffle.pauseRaffle();
    }

    function testPauseRaffleRevertsAlreadyPaused() public {
        vm.startPrank(raffle.getOwner());
        raffle.pauseRaffle();
        vm.expectRevert(Raffle.Raffle__AlreadyPaused.selector);
        raffle.pauseRaffle();
        vm.stopPrank();
    }

    function testRafflePausePausesWhenOwner() public {
        vm.prank(raffle.getOwner());
        vm.expectEmit(true, true, false, false, address(raffle));
        emit PausedRaffle(msg.sender, Raffle.RaffleState.PAUSED);
        raffle.pauseRaffle();
        assert(raffle.getRaffleState() == Raffle.RaffleState.PAUSED);
    }

    function testResumeRaffleRevertsWhenNotOwner() public {
        vm.expectRevert(Raffle.Raffle__NotOwner.selector);
        vm.prank(PLAYER);
        raffle.resumeRaffle();
    }

    function testResumeRaffleRevertsAlreadyOpen() public {
        vm.prank(raffle.getOwner());
        vm.expectRevert(Raffle.Raffle__AlreadyOpen.selector);
        raffle.resumeRaffle();
    }

    function testRaffleResumeResumessWhenOwner() public {
        vm.startPrank(raffle.getOwner());
        raffle.pauseRaffle();
        vm.expectEmit(true, true, false, false, address(raffle));
        emit ResumedRaffle(msg.sender, Raffle.RaffleState.OPEN);
        raffle.resumeRaffle();
        vm.stopPrank();
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    function testRefundRaffleRevertsWhenNotOwner() public {
        vm.expectRevert(Raffle.Raffle__NotOwner.selector);
        vm.prank(PLAYER);
        raffle.pauseRaffle();
    }

    function testRefundRaffleRefundsAndResetsRaffle() public {
        // Arrange
        uint256 additionalEntrances = 3;
        uint256 startingIndex = 1; // We have starting index be 1 so we can start with address(1) and not address(0)
        address payable[] memory s_players = new address payable[](additionalEntrances);
        uint256 raffleBalanceBefore = raffle.getBalance();

        for (uint256 i = startingIndex; i < startingIndex + additionalEntrances; i++) {
            address player = address(uint160(i));
            s_players[i - startingIndex] = payable(player);
            hoax(player, 1 ether); // deal 1 eth to the player
            raffle.enterRaffle{value: entranceFee}();
        }
        vm.expectEmit(true, true, false, false, address(raffle));
        emit RefundedRaffle(s_players, raffle.getEntranceFee());
        vm.prank(raffle.getOwner());
        raffle.refundRaffle();
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
        assert(raffle.getPlayersLength() == 0);
        assert(raffle.getLastTimeStamp() == block.timestamp);
        assert(raffle.getBalance() == raffleBalanceBefore);

        for (uint256 i = 0; i < s_players.length; i++) {
            assert(s_players[i].balance == 1 ether);
        }
    }

    /////////////////////////
    // enterRaffle         //
    /////////////////////////

    function testRaffleRevertsWhenYouDontPayEnought() public {
        vm.prank(PLAYER);
        vm.expectRevert(Raffle.Raffle__NotEnoughEthSent.selector);
        raffle.enterRaffle();
    }

    function testRaffleRecordsPlayerWhenTheyEnter() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        address playerRecorded = raffle.getPlayer(0);
        assert(playerRecorded == PLAYER);
    }

    function testEmitsEventOnEntrance() public {
        vm.prank(PLAYER);
        vm.expectEmit(true, false, false, false, address(raffle));
        emit EnteredRaffle(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    function testDontAllowPlayersToEnterWhileRaffleIsCalculating() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        raffle.performUpkeep("");

        vm.expectRevert(Raffle.Raffle__RaffleNotOpen.selector);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    /////////////////////////
    // checkUpkeep         //
    /////////////////////////

    function testCheckUpkeepReturnsFalseIfItHasNoBalance() public {
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        (bool upkeepNeeded,) = raffle.checkUpkeep("");

        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsFalseIfRaffleIsntOpen() public {
        // Arrange
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        raffle.performUpkeep("");
        Raffle.RaffleState raffleState = raffle.getRaffleState();
        // Act
        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        // Assert
        assert(raffleState == Raffle.RaffleState.CALCULATING);
        assert(upkeepNeeded == false);
    }

    function testCheckUpkeepReturnsFalseIfEnoughTimeHasntPassed() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.roll(block.number + 1);

        (bool upkeepNeeded,) = raffle.checkUpkeep("");

        assert(upkeepNeeded == false);
    }

    function testCheckUpkeepReturnsTrueWhenParametersGood() public {
        // Arrange
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        // Act
        (bool upkeepNeeded,) = raffle.checkUpkeep("");

        // Assert
        assert(upkeepNeeded);
    }

    /////////////////////////
    // performUpkeep       //
    /////////////////////////

    function testPerformUpkeepCanOnlyRunIfCheckUpkeepIsTrue() public {
        // Arrange
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        // Act / Assert
        // It doesnt revert
        raffle.performUpkeep("");
    }

    function testPerformUpkeepRevertsIfCheckUpkeepIsFalse() public {
        // Arrange
        uint256 currentBalance = raffle.getBalance();
        uint256 numPlayers = 0;
        Raffle.RaffleState rState = raffle.getRaffleState();
        // Act / Assert
        vm.expectRevert(
            abi.encodeWithSelector(Raffle.Raffle__UpkeepNotNeeded.selector, currentBalance, numPlayers, rState)
        );
        raffle.performUpkeep("");
    }

    function testPerformUpkeepUpdatesRaffleStateAndEmitsRequestId() public {
        // Arrange
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        // Act
        vm.recordLogs();
        raffle.performUpkeep(""); // emits requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[0].topics[2];

        // Assert
        Raffle.RaffleState raffleState = raffle.getRaffleState();
        assert(uint256(requestId) > 0);
        assert(uint256(raffleState) == 1); // 0 = open, 1 = calculating
    }

    /////////////////////////
    // fulfillRandomWords //
    ////////////////////////

    modifier skipFork() {
        if (block.chainid != 31337) {
            return;
        }
        _;
    }

    modifier raffleEntered() {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    function testFulfillRandomWordsCanOnlyBeCalledAfterPerformUpkeep(uint256 randomRequestId)
        public
        raffleEntered
        skipFork
    {
        // Arrange
        // Act / Assert
        vm.expectRevert("nonexistent request");
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(randomRequestId, address(raffle));
    }

    function testFulfillRandomWordsPicksAWinnerResetsAndSendsMoney() public raffleEntered skipFork {
        address expectedWinner = address(1);

        // Arrange
        uint256 additionalEntrances = 3;
        uint256 startingIndex = 1; // We have starting index be 1 so we can start with address(1) and not address(0)

        for (uint256 i = startingIndex; i < startingIndex + additionalEntrances; i++) {
            address player = address(uint160(i));
            hoax(player, 1 ether); // deal 1 eth to the player
            raffle.enterRaffle{value: entranceFee}();
        }

        uint256 startingTimeStamp = raffle.getLastTimeStamp();
        uint256 startingBalance = expectedWinner.balance;

        // // Act
        vm.recordLogs();
        raffle.performUpkeep(""); // emits requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[0].topics[2]; // get the requestId from the logs

        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(raffle));

        // Assert
        address recentWinner = raffle.getRecentWinner();
        Raffle.RaffleState raffleState = raffle.getRaffleState();
        uint256 winnerBalance = recentWinner.balance;
        uint256 endingTimeStamp = raffle.getLastTimeStamp();
        uint256 prize = entranceFee * (additionalEntrances + 1);

        assert(recentWinner == expectedWinner);
        assert(uint256(raffleState) == 0);
        assert(winnerBalance == startingBalance + prize);
        assert(endingTimeStamp > startingTimeStamp);
    }
}
