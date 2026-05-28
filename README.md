# GlassBridgeBet 
## Contributors

## Contributors


> A blockchain based betting game inspired by Squid Game's glass bridge challenge.
> Built with Solidity, Hardhat and MetaMask for IFB452 Blockchain Technology at QUT.

| Name | Contribution | Areas |
|------|-------------|-------|
| Kai Langley n12487465 | 80% Frontend, 20% Backend | Browser UI (HTML + ethers.js), MetaMask integration, game flow interface, smart contract support |
| Prabhanjan muthukannan n12459119| 80% Backend, 20% Frontend | Solidity smart contracts, Hardhat config, test suite, QUT Testnet deployment, frontend support |


**Live App:** [GitHub Pages link here]

---

## What is GlassBridgeBet?

A player crosses a virtual bridge by choosing left or right panels at each step. One panel is safe tempered glass and the other will shatter. If the player selects safe panel they win double their ETH bet. However if they select wrong they lose their ETH bet.
Spectators bet ETH on whether the player survives each step. Smart contracts handle all escrow, payouts and game logic there are no trusted bookmaker needed.

---

## Why Blockchain?

Traditional betting requires a trusted intermediary (bookmaker) who can manipulate odds, refuse payouts or disappear. GlassBridgeBet removes this entirely by....

- Multiple writers ---Front Man, Player, and Spectators all write state
- No trusted party ----Smart contracts enforce payouts automatically
- Transparent ----All bets and outcomes are publicly auditable on-chain
- Code enforcement ---Payout logic is deterministic and tamper-proof

---

## Architecture
```
Browser (HTML + ethers.js) → MetaMask → QUT Testnet → Smart Contracts
```

### Smart Contracts

| Contract | Purpose |
|---|---|
| `BettingVault.sol` | ETH escrow, bet tracking, pull-payment payouts |
| `GlassBridgeGame.sol` | Game logic, commit-reveal scheme, state machine |

**Contract-to-contract interaction:** After each step resolves, `GlassBridgeGame` directly calls `BettingVault.settleStep()` to calculate and distribute winnings.

### Deployed on QUT Testnet (Chain ID 452)

- **BettingVault:** `0x25bE1CFE0C9B8B18C0246adB5b1E366592E7429B`

- **GlassBridgeGame:** `0xcBE97d7aED03B80Bf32da44cF4Bc29b525Ea5c0c`

---

## Design Patterns

| Pattern | Where | Why |
|---|---|---|
| **Commit-reveal** | `startGame` + `revealPattern` | Prevents Front Man changing pattern after seeing bets |
| **Pull-payment** | `claimWinnings()` | Avoids gas limit issues with many winners |
| **CEI (Checks-Effects-Interactions)** | `claimWinnings()` | Prevents re-entrancy attacks |
| **ReentrancyGuard** | `claimWinnings()`, `withdrawFee()` | Second re-entrancy defence |
| **State machine** | `WAITING → BETTING → ACTIVE → ENDED` | Prevents out-of-order function calls |
| **Access control** | `onlyFrontMan`, `onlyGame` | Restricts sensitive functions |
| **Fallback refund** | `triggerRefund()` | Liveness guarantee if Front Man disappears |

---

## Stakeholders

| Role | Contract | Actions |
|---|---|---|
| Front Man | Both | Deploy, startGame, revealPattern, withdrawFee |
| Player | GlassBridgeGame | registerPlayer, makeChoice (LEFT/RIGHT) |
| Spectators | BettingVault | placeBet, claimWinnings |

---

## Game Flow

```
1. Front Man commits keccak256(pattern + salt) hash — BEFORE betting opens
2. Spectators place ETH bets on step outcomes
3. Player registers
4. Front Man reveals pattern — hash verified on-chain
5. Player crosses bridge step by step (LEFT or RIGHT)
6. After each step: GlassBridgeGame calls BettingVault.settleStep()
7. Spectators claim winnings via pull-payment
8. Front Man withdraws house fee
```

---

## Running Locally

### Prerequisites
- Node.js 18+
- MetaMask browser extension

### Setup
```bash
npm install
npx hardhat compile
npx hardhat test test/hardhat-test.cjs
```

### Run tests
... (61 lines left)

README.md
5 KB
