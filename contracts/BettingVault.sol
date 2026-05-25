// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BettingVault
 * @notice Handles ETH escrow, bet tracking, and pull-payment payouts
 *         for the GlassBridgeBet game. Only the registered game contract
 *         can call settleStep() — enforced by the onlyGame modifier.
 */
contract BettingVault is ReentrancyGuard {

    // ─────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────

    address public frontMan;
    address public gameContract;          // set once by setGameContract()
    uint8   public houseFeePercent;       // e.g. 5 = 5%

    // Pull-payment ledger: winner address => claimable ETH (wei)
    mapping(address => uint256) public balances;

    // Refund ledger: used when game is abandoned or step never reached
    mapping(address => uint256) public refundBalances;

    // Per-step bet storage
    struct Bet {
        address bettor;
        uint256 amount;
        bool    predictSurvive;   // true = player survives this step
    }
    mapping(uint256 => Bet[]) public betsPerStep;

    // Track total house fees accumulated
    uint256 public accumulatedFees;

    // Deadline block for fallback refund (set by game contract)
    uint256 public refundDeadlineBlock;
    bool    public refundModeActive;

    // ─────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────

    event BetPlaced(address indexed bettor, uint256 step, uint256 amount, bool predictSurvive);
    event StepSettled(uint256 indexed step, bool playerSurvived, uint256 totalPayout);
    event WinningsClaimed(address indexed bettor, uint256 amount);
    event FeeWithdrawn(address indexed frontMan, uint256 amount);
    event RefundClaimed(address indexed bettor, uint256 amount);
    event RefundModeActivated(uint256 deadlineBlock);

    // ─────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────

    modifier onlyFrontMan() {
        require(msg.sender == frontMan, "BettingVault: not front man");
        _;
    }

    /// @dev Only the registered GlassBridgeGame contract may call settleStep
    modifier onlyGame() {
        require(msg.sender == gameContract, "BettingVault: caller is not game contract");
        _;
    }

    // ─────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────

    constructor(uint8 _houseFeePercent) {
        require(_houseFeePercent <= 20, "BettingVault: fee too high");
        frontMan        = msg.sender;
        houseFeePercent = _houseFeePercent;
    }

    // ─────────────────────────────────────────
    //  Setup
    // ─────────────────────────────────────────

    /**
     * @notice Called once by Front Man after deploying GlassBridgeGame.
     *         Links the two contracts so onlyGame can restrict settleStep().
     */
    function setGameContract(address _gameContract) external onlyFrontMan {
        require(gameContract == address(0), "BettingVault: game already set");
        require(_gameContract != address(0), "BettingVault: zero address");
        gameContract = _gameContract;
    }

    // ─────────────────────────────────────────
    //  Spectator: place bet
    // ─────────────────────────────────────────

    /**
     * @notice Spectator deposits ETH and records a bet on a specific step.
     * @param step          The bridge step index (1-based) to bet on
     * @param predictSurvive  true = player survives, false = player dies
     */
    function placeBet(uint256 step, bool predictSurvive) external payable {
        require(!refundModeActive, "BettingVault: refund mode active");
        require(msg.value > 0, "BettingVault: bet must be > 0");
        require(step > 0, "BettingVault: step must be > 0");

        betsPerStep[step].push(Bet({
            bettor:         msg.sender,
            amount:         msg.value,
            predictSurvive: predictSurvive
        }));

        emit BetPlaced(msg.sender, step, msg.value, predictSurvive);
    }

    // ─────────────────────────────────────────
    //  Game → Vault: settle a step (contract-to-contract call)
    // ─────────────────────────────────────────

    /**
     * @notice Called by GlassBridgeGame after each step resolves.
     *         Calculates winners, deducts house fee, updates pull-payment balances.
     *         This is the key contract-to-contract interaction in the system.
     * @param step           The step that just resolved
     * @param playerSurvived Whether the player chose correctly
     */
    function settleStep(uint256 step, bool playerSurvived) external onlyGame {
        Bet[] storage bets = betsPerStep[step];
        if (bets.length == 0) return;

        // Calculate total pool and winning pool
        uint256 totalPool    = 0;
        uint256 winningPool  = 0;

        for (uint256 i = 0; i < bets.length; i++) {
            totalPool += bets[i].amount;
            if (bets[i].predictSurvive == playerSurvived) {
                winningPool += bets[i].amount;
            }
        }

        // House fee taken from total pool
        uint256 fee        = (totalPool * houseFeePercent) / 100;
        uint256 payoutPool = totalPool - fee;
        accumulatedFees   += fee;

        // Distribute proportionally to winners; losers' bets become refundable
        for (uint256 i = 0; i < bets.length; i++) {
            if (bets[i].predictSurvive == playerSurvived) {
                // Winner gets proportional share of payout pool
                // Checks-Effects-Interactions: update state before any transfer
                uint256 payout = (bets[i].amount * payoutPool) / winningPool;
                balances[bets[i].bettor] += payout;
            }
            // Losers get nothing — their ETH stays in the pool as winnings
        }

        emit StepSettled(step, playerSurvived, payoutPool);
    }

    // ─────────────────────────────────────────
    //  Spectator: claim winnings (pull-payment)
    // ─────────────────────────────────────────

    /**
     * @notice Pull-payment: spectator calls this themselves to withdraw winnings.
     *         Uses CEI pattern — balance zeroed BEFORE transfer to prevent re-entrancy.
     */
    function claimWinnings() external nonReentrant {
        // CHECKS
        uint256 amount = balances[msg.sender];
        require(amount > 0, "BettingVault: nothing to claim");

        // EFFECTS — zero balance before interaction
        balances[msg.sender] = 0;

        // INTERACTIONS
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "BettingVault: transfer failed");

        emit WinningsClaimed(msg.sender, amount);
    }

    // ─────────────────────────────────────────
    //  Front Man: collect house fee
    // ─────────────────────────────────────────

    function withdrawFee() external onlyFrontMan nonReentrant {
        uint256 amount = accumulatedFees;
        require(amount > 0, "BettingVault: no fees");

        // CEI
        accumulatedFees = 0;
        (bool success, ) = payable(frontMan).call{value: amount}("");
        require(success, "BettingVault: transfer failed");

        emit FeeWithdrawn(frontMan, amount);
    }

    // ─────────────────────────────────────────
    //  Fallback refund — Front Man liveness protection
    // ─────────────────────────────────────────

    /**
     * @notice Called by game contract when it activates refund mode
     *         (e.g. Front Man never revealed the pattern within the deadline).
     *         Allows spectators to reclaim their original bet amounts.
     */
    function activateRefundMode(uint256 deadlineBlock) external onlyGame {
        refundModeActive      = true;
        refundDeadlineBlock   = deadlineBlock;

        // Move all un-settled bets into refund balances
        // Note: in production you'd iterate per step; here simplified for demo
        emit RefundModeActivated(deadlineBlock);
    }

    /**
     * @notice Spectator reclaims bet from a specific step when refund mode is active.
     * @param step The step the spectator originally bet on
     */
    function claimRefund(uint256 step) external nonReentrant {
        require(refundModeActive, "BettingVault: not in refund mode");

        Bet[] storage bets = betsPerStep[step];
        uint256 refundAmount = 0;

        for (uint256 i = 0; i < bets.length; i++) {
            if (bets[i].bettor == msg.sender && bets[i].amount > 0) {
                refundAmount    += bets[i].amount;
                bets[i].amount   = 0;  // CEI: zero before transfer
            }
        }

        require(refundAmount > 0, "BettingVault: no refund available");

        (bool success, ) = payable(msg.sender).call{value: refundAmount}("");
        require(success, "BettingVault: refund transfer failed");

        emit RefundClaimed(msg.sender, refundAmount);
    }

    // ─────────────────────────────────────────
    //  View helpers
    // ─────────────────────────────────────────

    function getBetsForStep(uint256 step) external view returns (Bet[] memory) {
        return betsPerStep[step];
    }

    function getBalance(address addr) external view returns (uint256) {
        return balances[addr];
    }

    function contractBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
