const hre = require("hardhat");
const ethers = hre.ethers;
const fs = require("fs");

function sep(title) {
  console.log(`\n${"─".repeat(55)}`);
  console.log(`  ${title}`);
  console.log("─".repeat(55));
}

async function main() {
  const signers = await ethers.getSigners();
  const frontMan   = signers[0];
  const player     = signers[1];
  const spectator1 = signers[2];
  const spectator2 = signers[3];

  console.log("🎮 GlassBridgeBet — Full Game Demo");
  console.log("Front Man  :", frontMan.address);
  console.log("Player     :", player.address);
  console.log("Spectator 1:", spectator1.address);
  console.log("Spectator 2:", spectator2.address);

  // Load deployment
  console.log("\nDeploying contracts...");
  const VaultFactory = await ethers.getContractFactory("BettingVault", frontMan);
  const vault = await VaultFactory.deploy(5);
  await vault.waitForDeployment();
  console.log("BettingVault:", await vault.getAddress());

  const GameFactory = await ethers.getContractFactory("GlassBridgeGame", frontMan);
  const game = await GameFactory.deploy(await vault.getAddress());
  await game.waitForDeployment();
  console.log("GlassBridgeGame:", await game.getAddress());

  await vault.setGameContract(await game.getAddress());
  console.log("Contracts linked.\n");

  // Bridge pattern: "LRLLR" — L = left safe, R = right safe
  const PATTERN = "LRLLR";
  const SALT    = ethers.encodeBytes32String("glasssalt42");
  const PATTERN_HASH = ethers.keccak256(
    ethers.solidityPacked(["string", "bytes32"], [PATTERN, SALT])
  );

  console.log(`\nBridge pattern (SECRET): "${PATTERN}"`);
  console.log("Pattern hash (PUBLIC):  ", PATTERN_HASH);

  // PHASE 1: Start game
  sep("PHASE 1 — Front Man starts game, commits hash");
  let tx = await game.startGame(5, PATTERN_HASH);
  await tx.wait();
  console.log("✅ startGame(5 steps, patternHash) — state: BETTING");

  // PHASE 2: Place bets
  sep("PHASE 2 — Spectators place bets");
  tx = await vault.connect(spectator1).placeBet(1, true, { value: ethers.parseEther("0.1") });
  await tx.wait();
  console.log("✅ Spectator 1: 0.1 ETH on step 1, predicts SURVIVE");

  tx = await vault.connect(spectator1).placeBet(3, true, { value: ethers.parseEther("0.05") });
  await tx.wait();
  console.log("✅ Spectator 1: 0.05 ETH on step 3, predicts SURVIVE");

  tx = await vault.connect(spectator2).placeBet(1, false, { value: ethers.parseEther("0.1") });
  await tx.wait();
  console.log("✅ Spectator 2: 0.1 ETH on step 1, predicts ELIMINATED");

  tx = await vault.connect(spectator2).placeBet(2, false, { value: ethers.parseEther("0.08") });
  await tx.wait();
  console.log("✅ Spectator 2: 0.08 ETH on step 2, predicts ELIMINATED");

  const vaultBal = await ethers.provider.getBalance(await vault.getAddress());
  console.log("\nVault balance:", ethers.formatEther(vaultBal), "ETH");

  // Register player
  tx = await game.connect(player).registerPlayer();
  await tx.wait();
  console.log("\n✅ Player registered");

  // PHASE 3: Reveal pattern
  sep("PHASE 3 — Front Man reveals pattern (hash verified on-chain)");
  tx = await game.revealPattern(PATTERN, SALT);
  await tx.wait();
  console.log(`✅ revealPattern("${PATTERN}", salt) — hash verified ✓`);
  console.log("   State: ACTIVE");

  // PHASE 4: Player crosses bridge
  sep("PHASE 4 — Player crosses bridge step by step");
  console.log("Pattern: L R L L R");
  console.log("         1 2 3 4 5\n");

  const choices = [true, false, true, true, false]; // L R L L R
  const labels  = ["L", "R", "L", "L", "R"];

  for (let i = 0; i < choices.length; i++) {
    const step = i + 1;
    tx = await game.connect(player).makeChoice(choices[i]);
    const receipt = await tx.wait();

    let survived = null;
    for (const log of receipt.logs) {
      try {
        const parsed = game.interface.parseLog(log);
        if (parsed.name === "StepAttempted") survived = parsed.args.survived;
        if (parsed.name === "PlayerWon") console.log("\n🏆 PlayerWon event emitted!");
        if (parsed.name === "PlayerEliminated") console.log(`\n💀 PlayerEliminated at step ${step}`);
      } catch {}
    }
    console.log(`Step ${step}: chose ${labels[i]} → ${survived ? "✅ SURVIVED" : "❌ ELIMINATED"}`);
    if (survived !== null) {
      console.log(`   → GlassBridgeGame called BettingVault.settleStep(${step}, ${survived})`);
    }
    if (!survived) break;
  }
  // PHASE 5: Claim winnings
  sep("PHASE 5 — Spectators claim winnings (pull-payment)");
  const s1Bal = await vault.getBalance(spectator1.address);
  const s2Bal = await vault.getBalance(spectator2.address);
  console.log("Spectator 1 claimable:", ethers.formatEther(s1Bal), "ETH");
  console.log("Spectator 2 claimable:", ethers.formatEther(s2Bal), "ETH");

  if (s1Bal > 0n) {
    tx = await vault.connect(spectator1).claimWinnings();
    await tx.wait();
    console.log("✅ Spectator 1 claimed winnings");
  }
  if (s2Bal > 0n) {
    tx = await vault.connect(spectator2).claimWinnings();
    await tx.wait();
    console.log("✅ Spectator 2 claimed winnings");
  }

  // PHASE 6: Front Man collects fee
  sep("PHASE 6 — Front Man withdraws house fee");
  const fees = await vault.accumulatedFees();
  console.log("Accumulated fee:", ethers.formatEther(fees), "ETH");
  if (fees > 0n) {
    tx = await vault.withdrawFee();
    await tx.wait();
    console.log("✅ Front Man withdrew fee");
  }

  // Final balances
  sep("FINAL BALANCES");
  const fmt = async (signer, name) => {
    const bal = await ethers.provider.getBalance(signer.address);
    console.log(`${name}: ${parseFloat(ethers.formatEther(bal)).toFixed(4)} ETH`);
  };
  await fmt(frontMan,   "Front Man  ");
  await fmt(player,     "Player     ");
  await fmt(spectator1, "Spectator 1");
  await fmt(spectator2, "Spectator 2");
  const vaultFinal = await ethers.provider.getBalance(await vault.getAddress()); 
  console.log("Vault      :", ethers.formatEther(vaultFinal), "ETH");

  console.log("\n✅ Full game lifecycle complete!\n");
}

main().catch(console.error);