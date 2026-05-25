// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BettingVault.sol";

/**
 * @title GlassBridgeGame
 * @notice Game logic for GlassBridgeBet. Implements:
 *   - Commit-reveal scheme for fair pattern commitment
 *   - State machine (WAITING → BETTING → ACTIVE → ENDED)
 *   - Contract-to-contract interaction with BettingVault
 *   - Fallback refund trigger if Front Man disappears
 */
contract GlassBridgeGame {

    // ─────────────────────────────────────────
    //  Types
    // ─────────────────────────────────────────

    enum GameState { WAITING, BETTING, ACTIVE, ENDED }

    struct Player {
        address addr;
        uint256 currentStep;   // 0 = not started
        bool    alive;
        bool    registered;
    }

    // ─────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────

    address      public frontMan;
    BettingVault public bettingVault;       // contract-to-contract reference

    GameState    public state;
    uint256      public totalSteps;
    uint256      public currentGameId;

    // Commit-reveal
    bytes32      public committedPatternHash;  // keccak256(pattern + salt) committed before betting
    string       public revealedPattern;       // e.g. "LRLRRL" (L=left safe, R=right safe)
    bool         public patternRevealed;

    // Liveness: if reveal not called within this many blocks after ACTIVE, refund triggered
    uint256      public revealDeadlineBlock;
    uint256      public constant REVEAL_WINDOW = 200; // ~40 minutes on mainnet

    // Player tracking (one player per round)
    Player       public currentPlayer;

    // ─────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────

    event GameStarted(uint256 indexed gameId, uint256 totalSteps, bytes32 patternHash);
    event BettingClosed(uint256 indexed gameId);
    event PatternRevealed(uint256 indexed gameId, string pattern);
    event PlayerRegistered(address indexed player);
    event StepAttempted(address indexed player, uint256 step, bool choseLeft, bool survived);
    event PlayerEliminated(address indexed player, uint256 atStep);
    event PlayerWon(address indexed player);
    event GameEnded(uint256 indexed gameId);
    event RefundTriggered(uint256 indexed gameId);

    // ─────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────

    modifier onlyFrontMan() {
        require(msg.sender == frontMan, "GlassBridgeGame: not front man");
        _;
    }

    modifier inState(GameState _state) {
        require(state == _state, "GlassBridgeGame: wrong game state");
        _;
    }

    // ─────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────

    /**
     * @param _bettingVault Address of the already-deployed BettingVault
     */
    constructor(address _bettingVault) {
        require(_bettingVault != address(0), "GlassBridgeGame: zero vault address");
        frontMan     = msg.sender;
        bettingVault = BettingVault(_bettingVault);
        state        = GameState.WAITING;
    }

    // ─────────────────────────────────────────
    //  Phase 1: Front Man starts game + commits pattern
    // ─────────────────────────────────────────

    /**
     * @notice Front Man commits the bridge pattern hash BEFORE betting opens.
     *         This prevents the Front Man from changing the pattern after seeing bets.
     *         Pattern is committed as keccak256(abi.encodePacked(pattern, salt)).
     *
     * @param _steps       Number of bridge steps (e.g. 5)
     * @param _patternHash keccak256(abi.encodePacked(pattern, salt)) computed off-chain
     *
     * Off-chain helper to compute hash:
     *   ethers.utils.keccak256(ethers.utils.solidityPack(["string","bytes32"], [pattern, salt]))
     */
    function startGame(uint256 _steps, bytes32 _patternHash)
        external
        onlyFrontMan
        inState(GameState.WAITING)
    {
        require(_steps > 0 && _steps <= 20, "GlassBridgeGame: steps 1-20");
        require(_patternHash != bytes32(0), "GlassBridgeGame: invalid hash");

        currentGameId++;
        totalSteps           = _steps;
        committedPatternHash = _patternHash;
        patternRevealed      = false;
        revealedPattern      = "";
        state                = GameState.BETTING;

        // Reset player
        delete currentPlayer;

        // Set reveal deadline (starts counting from now)
        revealDeadlineBlock = block.number + REVEAL_WINDOW;

        emit GameStarted(currentGameId, _steps, _patternHash);
    }

    // ─────────────────────────────────────────
    //  Phase 2: Spectators bet (handled in BettingVault), player registers
    // ─────────────────────────────────────────

    /**
     * @notice Player registers to participate in the current round.
     *         Registration is open while state is BETTING.
     */
    function registerPlayer() external inState(GameState.BETTING) {
        require(!currentPlayer.registered, "GlassBridgeGame: player already registered");
        currentPlayer = Player({
            addr:        msg.sender,
            currentStep: 0,
            alive:       true,
            registered:  true
        });
        emit PlayerRegistered(msg.sender);
    }

    // ─────────────────────────────────────────
    //  Phase 3: Front Man reveals pattern
    // ─────────────────────────────────────────

    /**
     * @notice Front Man reveals the bridge pattern. Contract verifies the hash
     *         matches the committed hash — proves the pattern wasn't changed.
     *
     * @param pattern  String of 'L' and 'R' chars, length == totalSteps
     *                 'L' = left panel is safe, 'R' = right panel is safe
     * @param salt     The salt used when computing the committed hash
     */
    function revealPattern(string calldata pattern, bytes32 salt)
        external
        onlyFrontMan
        inState(GameState.BETTING)
    {
        require(currentPlayer.registered, "GlassBridgeGame: no player registered");

        // Verify: recompute hash and compare to committed value
        bytes32 computedHash = keccak256(abi.encodePacked(pattern, salt));
        require(computedHash == committedPatternHash, "GlassBridgeGame: hash mismatch - pattern tampered");

        // Validate pattern length matches totalSteps
        bytes memory patternBytes = bytes(pattern);
        require(patternBytes.length == totalSteps, "GlassBridgeGame: pattern length mismatch");

        // Validate each character is 'L' or 'R'
        for (uint256 i = 0; i < patternBytes.length; i++) {
            require(
                patternBytes[i] == "L" || patternBytes[i] == "R",
                "GlassBridgeGame: invalid pattern char"
            );
        }

        revealedPattern = pattern;
        patternRevealed = true;
        state           = GameState.ACTIVE;

        emit PatternRevealed(currentGameId, pattern);
    }

    // ─────────────────────────────────────────
    //  Phase 4: Player makes choices step-by-step
    // ─────────────────────────────────────────

    /**
     * @notice Player chooses left or right panel for the next step.
     *         Contract checks against revealedPattern and calls BettingVault.settleStep().
     *
     * @param goLeft  true = choose left panel, false = choose right panel
     */
    function makeChoice(bool goLeft) external inState(GameState.ACTIVE) {
        require(msg.sender == currentPlayer.addr, "GlassBridgeGame: not the registered player");
        require(currentPlayer.alive, "GlassBridgeGame: player already eliminated");
        require(patternRevealed, "GlassBridgeGame: pattern not revealed");

        uint256 nextStep = currentPlayer.currentStep + 1;
        require(nextStep <= totalSteps, "GlassBridgeGame: all steps completed");

        // Determine correct choice from revealed pattern
        // Pattern index is 0-based, step is 1-based
        bytes1 safePanel = bytes(revealedPattern)[nextStep - 1];
        bool safeIsLeft  = (safePanel == "L");
        bool survived    = (goLeft == safeIsLeft);

        currentPlayer.currentStep = nextStep;

        emit StepAttempted(currentPlayer.addr, nextStep, goLeft, survived);

        // ─── Contract-to-Contract Interaction ───
        // Call BettingVault.settleStep() to calculate payouts for bets on this step
        bettingVault.settleStep(nextStep, survived);
        // ─────────────────────────────────────────

        if (!survived) {
            currentPlayer.alive = false;
            state = GameState.ENDED;
            emit PlayerEliminated(currentPlayer.addr, nextStep);
            emit GameEnded(currentGameId);
            _resetForNextGame();
        } else if (nextStep == totalSteps) {
            // Player completed all steps
            state = GameState.ENDED;
            emit PlayerWon(currentPlayer.addr);
            emit GameEnded(currentGameId);
            _resetForNextGame();
        }
    }

    // ─────────────────────────────────────────
    //  Fallback: trigger refund if Front Man disappears
    // ─────────────────────────────────────────

    /**
     * @notice Anyone can call this if the reveal deadline has passed
     *         and the pattern still hasn't been revealed.
     *         Activates refund mode in BettingVault so spectators reclaim ETH.
     */
    function triggerRefund() external inState(GameState.BETTING) {
        require(block.number > revealDeadlineBlock, "GlassBridgeGame: deadline not passed");
        require(!patternRevealed, "GlassBridgeGame: pattern already revealed");

        state = GameState.ENDED;

        // Tell vault to activate refund mode — contract-to-contract call
        bettingVault.activateRefundMode(block.number);

        emit RefundTriggered(currentGameId);
        emit GameEnded(currentGameId);
        _resetForNextGame();
    }

    // ─────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────

    function _resetForNextGame() internal {
        state = GameState.WAITING;
    }

    // ─────────────────────────────────────────
    //  View helpers
    // ─────────────────────────────────────────

    function getGameState() external view returns (
        GameState _state,
        uint256   _gameId,
        uint256   _totalSteps,
        bool      _patternRevealed,
        bool      _playerRegistered,
        address   _playerAddr,
        uint256   _playerStep,
        bool      _playerAlive
    ) {
        return (
            state,
            currentGameId,
            totalSteps,
            patternRevealed,
            currentPlayer.registered,
            currentPlayer.addr,
            currentPlayer.currentStep,
            currentPlayer.alive
        );
    }

    /**
     * @notice Off-chain helper: compute the pattern hash to pass to startGame().
     *         You can also compute this in JS with ethers.js.
     */
    function computePatternHash(string calldata pattern, bytes32 salt)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(pattern, salt));
    }
}
