// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/**
 * @title A sample Raffle contract
 * @author Will Urban
 * @notice This contract is for creating a sample raffle
 * @dev Implements Chainlink VRFv2
 */
contract Raffle {
    error Raffle__NotEnoughEthSent();

    uint256 private immutable i_entranceFee;
    // @dev Duration of the lottery in seconds
    uint256 private immutable i_interval;
    address payable[] private s_players;
    uint256 private s_lastTimeStamp;

    /**
     * Events
     */

    event EnteredRaffle(address indexed player);

    constructor(uint256 entraceFee, uint256 interval) {
        i_entranceFee = entraceFee;
        i_interval = interval;
        s_lastTimeStamp = block.timestamp;
    }

    function enterRaffle() external payable {
        require(msg.value >= i_entranceFee, "Not enough ETH sent!");
        if (msg.value >= i_entranceFee) {
            revert Raffle__NotEnoughEthSent();
        }
        s_players.push(payable(msg.sender));

        emit EnteredRaffle(msg.sender);
    }

    function picWinner() external {
        if ((block.timestamp - s_lastTimeStamp) < s_lastTimeStamp) {
            revert();
        }
    }

    /**
     * Getter Functions
     */

    function getEntranceFee() external view returns (uint256) {
        return i_entranceFee;
    }
}
