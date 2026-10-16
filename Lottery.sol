// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Lottery
 * @notice Supports three modes: Ticket-based, Pool-based, Raffle
 * @dev Deploy on BOT Chain (chain ID 968)
 *
 * WARNING: Uses block-based pseudo-randomness. For production,
 * integrate a VRF oracle (e.g. Chainlink VRF) for fair randomness.
 */
contract Lottery {

    // ─────────────────────────────────────────────
    //  Enums & Structs
    // ─────────────────────────────────────────────

    enum Mode { Ticket, Pool, Raffle }
    enum State { Inactive, Active, Drawing, Closed }

    struct Round {
        uint256 id;
        Mode    mode;
        State   state;
        uint256 ticketPrice;   // wei per ticket
        uint256 maxTickets;    // 0 = unlimited (not used in Pool mode)
        uint256 startTime;
        uint256 endTime;       // 0 = manual close
        uint256 jackpot;       // total prize pool (wei)
        address winner;
        uint256 winnerTicket;
        bool    settled;
    }

    // ─────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────

    address public owner;
    uint256 public feePercent;        // e.g. 5 = 5%
    uint256 public accumulatedFees;

    uint256 public currentRoundId;
    mapping(uint256 => Round) public rounds;

    // roundId => list of ticket holders (duplicates = multiple tickets)
    mapping(uint256 => address[]) public tickets;

    // roundId => player => ticket count
    mapping(uint256 => mapping(address => uint256)) public playerTickets;

    // roundId => pool contribution per address
    mapping(uint256 => mapping(address => uint256)) public poolContrib;
    mapping(uint256 => address[]) public poolParticipants;

    // past winners list
    struct WinRecord {
        uint256 roundId;
        Mode    mode;
        address winner;
        uint256 prize;
        uint256 timestamp;
    }
    WinRecord[] public winHistory;

    // ─────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────

    event RoundStarted(uint256 indexed roundId, Mode mode, uint256 ticketPrice, uint256 maxTickets);
    event TicketPurchased(uint256 indexed roundId, address indexed buyer, uint256 count, uint256 totalTickets);
    event PoolContributed(uint256 indexed roundId, address indexed contributor, uint256 amount);
    event RoundClosed(uint256 indexed roundId);
    event WinnerDrawn(uint256 indexed roundId, address indexed winner, uint256 prize);
    event FeeWithdrawn(address indexed to, uint256 amount);

    // ─────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier roundActive() {
        Round storage r = rounds[currentRoundId];
        require(r.state == State.Active, "No active round");
        if (r.endTime > 0) {
            require(block.timestamp <= r.endTime, "Round expired");
        }
        _;
    }

    // ─────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────

    constructor(uint256 _feePercent) {
        require(_feePercent <= 20, "Fee too high");
        owner = msg.sender;
        feePercent = _feePercent;
    }

    // ─────────────────────────────────────────────
    //  Admin: Start Round
    // ─────────────────────────────────────────────

    /**
     * @param mode       0=Ticket, 1=Pool, 2=Raffle
     * @param ticketPrice price per ticket in wei (Pool: minimum contribution)
     * @param maxTickets  max tickets (Raffle: cap; Ticket: 0=unlimited; Pool: ignored)
     * @param duration   seconds until auto-close (0 = manual)
     */
    function startRound(
        Mode mode,
        uint256 ticketPrice,
        uint256 maxTickets,
        uint256 duration
    ) external onlyOwner {
        Round storage prev = rounds[currentRoundId];
        require(
            currentRoundId == 0 || prev.state == State.Closed,
            "Previous round still open"
        );

        currentRoundId++;
        Round storage r = rounds[currentRoundId];
        r.id          = currentRoundId;
        r.mode        = mode;
        r.state       = State.Active;
        r.ticketPrice = ticketPrice;
        r.maxTickets  = maxTickets;
        r.startTime   = block.timestamp;
        r.endTime     = duration > 0 ? block.timestamp + duration : 0;

        emit RoundStarted(currentRoundId, mode, ticketPrice, maxTickets);
    }

    // ─────────────────────────────────────────────
    //  Buy Tickets (Ticket & Raffle modes)
    // ─────────────────────────────────────────────

    function buyTickets(uint256 count) external payable roundActive {
        Round storage r = rounds[currentRoundId];
        require(r.mode == Mode.Ticket || r.mode == Mode.Raffle, "Use contribute() for Pool mode");
        require(count > 0, "Buy at least 1");
        require(msg.value == r.ticketPrice * count, "Wrong ETH amount");

        if (r.maxTickets > 0) {
            require(tickets[currentRoundId].length + count <= r.maxTickets, "Exceeds max tickets");
        }

        for (uint256 i = 0; i < count; i++) {
            tickets[currentRoundId].push(msg.sender);
        }
        playerTickets[currentRoundId][msg.sender] += count;
        r.jackpot += msg.value;

        emit TicketPurchased(currentRoundId, msg.sender, count, tickets[currentRoundId].length);
    }

    // ─────────────────────────────────────────────
    //  Contribute (Pool mode)
    // ─────────────────────────────────────────────

    function contribute() external payable roundActive {
        Round storage r = rounds[currentRoundId];
        require(r.mode == Mode.Pool, "Use buyTickets() for Ticket/Raffle modes");
        require(msg.value >= r.ticketPrice, "Below minimum contribution");

        if (poolContrib[currentRoundId][msg.sender] == 0) {
            poolParticipants[currentRoundId].push(msg.sender);
        }
        poolContrib[currentRoundId][msg.sender] += msg.value;
        r.jackpot += msg.value;

        emit PoolContributed(currentRoundId, msg.sender, msg.value);
    }

    // ─────────────────────────────────────────────
    //  Admin: Close Round (manual or check expiry)
    // ─────────────────────────────────────────────

    function closeRound() external onlyOwner {
        Round storage r = rounds[currentRoundId];
        require(r.state == State.Active, "Round not active");
        r.state = State.Drawing;
        emit RoundClosed(currentRoundId);
    }

    // ─────────────────────────────────────────────
    //  Admin: Draw Winner
    // ─────────────────────────────────────────────

    function drawWinner() external onlyOwner {
        Round storage r = rounds[currentRoundId];
        require(r.state == State.Drawing, "Must close round first");
        require(!r.settled, "Already settled");

        uint256 participants;
        if (r.mode == Mode.Pool) {
            participants = poolParticipants[currentRoundId].length;
        } else {
            participants = tickets[currentRoundId].length;
        }
        require(participants > 0, "No participants");

        // Pseudo-random — replace with VRF in production
        uint256 rand = uint256(
            keccak256(abi.encodePacked(block.timestamp, block.prevrandao, participants, currentRoundId))
        ) % participants;

        address winner;
        if (r.mode == Mode.Pool) {
            winner = poolParticipants[currentRoundId][rand];
        } else {
            winner = tickets[currentRoundId][rand];
            r.winnerTicket = rand;
        }

        r.winner  = winner;
        r.settled = true;
        r.state   = State.Closed;

        uint256 fee   = (r.jackpot * feePercent) / 100;
        uint256 prize = r.jackpot - fee;
        accumulatedFees += fee;

        (bool sent, ) = winner.call{value: prize}("");
        require(sent, "Transfer failed");

        winHistory.push(WinRecord({
            roundId:   r.id,
            mode:      r.mode,
            winner:    winner,
            prize:     prize,
            timestamp: block.timestamp
        }));

        emit WinnerDrawn(currentRoundId, winner, prize);
    }

    // ─────────────────────────────────────────────
    //  Admin: Withdraw Fees
    // ─────────────────────────────────────────────

    function withdrawFees(address payable to) external onlyOwner {
        uint256 amount = accumulatedFees;
        require(amount > 0, "Nothing to withdraw");
        accumulatedFees = 0;
        (bool sent, ) = to.call{value: amount}("");
        require(sent, "Transfer failed");
        emit FeeWithdrawn(to, amount);
    }

    // ─────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────

    function getCurrentRound() external view returns (Round memory) {
        return rounds[currentRoundId];
    }

    function getTickets(uint256 roundId) external view returns (address[] memory) {
        return tickets[roundId];
    }

    function getPoolParticipants(uint256 roundId) external view returns (address[] memory) {
        return poolParticipants[roundId];
    }

    function getWinHistory() external view returns (WinRecord[] memory) {
        return winHistory;
    }

    function getWinHistoryLength() external view returns (uint256) {
        return winHistory.length;
    }

    function getPlayerTickets(uint256 roundId, address player) external view returns (uint256) {
        return playerTickets[roundId][player];
    }

    function getPoolContrib(uint256 roundId, address player) external view returns (uint256) {
        return poolContrib[roundId][player];
    }

    function totalTicketsSold(uint256 roundId) external view returns (uint256) {
        return tickets[roundId].length;
    }

    function totalPoolParticipants(uint256 roundId) external view returns (uint256) {
        return poolParticipants[roundId].length;
    }
}
