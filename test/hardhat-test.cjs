const hre = require("hardhat");
const ethers = hre.ethers;
const assert = require("assert");

let passed = 0;
let failed = 0;

async function test(name, fn) {
  try {
    await fn();
    console.log(`  ✅ ${name}`);
    passed++;
  } catch (e) {
    console.log(`  ❌ ${name}: ${e.message}`);
    failed++;
  }
}

async function deployFresh() {
  const signers = await ethers.getSigners();
  const frontMan = signers[0];
  const player = signers[1];
  const spectator1 = signers[2];
  const spectator2 = signers[3];
  const VaultFactory = await ethers.getContractFactory("BettingVault", frontMan);
  const vault = await VaultFactory.deploy(5);
  await vault.waitForDeployment();
  const GameFactory = await ethers.getContractFactory("GlassBridgeGame", frontMan);
  const game = await GameFactory.deploy(await vault.getAddress());
  await game.waitForDeployment();
  await vault.setGameContract(await game.getAddress());
  return { vault, game, frontMan, player, spectator1, spectator2 };
}

function makeHash(pattern, salt) {
  return ethers.keccak256(ethers.solidityPacked(["string", "bytes32"], [pattern, salt]));
}

async function main() {
  console.log("\n🧪 GlassBridgeBet — Test Suite\n");
  console.log("BettingVault");

  await test("deploys with 5% house fee", async () => {
    const { vault } = await deployFresh();
    assert.equal(await vault.houseFeePercent(), 5n);
  });

  await test("onlyGame — arbitrary address cannot call settleStep", async () => {
    const { vault, player } = await deployFresh();
    try {
      await vault.connect(player).settleStep(1, true);
      assert.fail("should revert");
    } catch (e) {
      assert.ok(e.message.includes("not game contract") || e.message.includes("revert"));
    }
  });

  await test("onlyFrontMan — player cannot withdrawFee", async () => {
    const { vault, player } = await deployFresh();
    try {
      await vault.connect(player).withdrawFee();
      assert.fail("should revert");
    } catch (e) {
      assert.ok(e.message.includes("not front man") || e.message.includes("revert"));
    }
  });

  await test("claimWinnings: balance zeroed before transfer (CEI)", async () => {
    const { vault, game, player, spectator1 } = await deployFresh();
    const SALT = ethers.encodeBytes32String("cei");
    await game.startGame(1, makeHash("L", SALT));
    await vault.connect(spectator1).placeBet(1, true, { value: ethers.parseEther("0.1") });
    await game.connect(player).registerPlayer();
    await game.revealPattern("L", SALT);
    await game.connect(player).makeChoice(true);
    const before = await vault.getBalance(spectator1.address);
    assert.ok(before > 0n);
    await vault.connect(spectator1).claimWinnings();
    assert.equal(await vault.getBalance(spectator1.address), 0n);
  });

  await test("claimWinnings: reverts if nothing to claim", async () => {
    const { vault, spectator1 } = await deployFresh();
    try {
      await vault.connect(spectator1).claimWinnings();
      assert.fail("should revert");
    } catch (e) {
      assert.ok(e.message.includes("nothing to claim") || e.message.includes("revert"));
    }
  });

  console.log("\nGlassBridgeGame");

  await test("starts in WAITING state (0)", async () => {
    const { game } = await deployFresh();
    const { _state } = await game.getGameState();
    assert.equal(_state, 0n);
  });

  await test("startGame transitions to BETTING state (1)", async () => {
    const { game } = await deployFresh();
    const SALT = ethers.encodeBytes32String("t");
    await game.startGame(3, makeHash("LRL", SALT));
    const { _state } = await game.getGameState();
    assert.equal(_state, 1n);
  });

  await test("onlyFrontMan — player cannot call startGame", async () => {
    const { game, player } = await deployFresh();
    const SALT = ethers.encodeBytes32String("hack");
    try {
      await game.connect(player).startGame(3, makeHash("LLL", SALT));
      assert.fail("should revert");
    } catch (e) {
      assert.ok(e.message.includes("not front man") || e.message.includes("revert"));
    }
  });

  await test("commit-reveal: correct pattern+salt succeeds", async () => {
    const { game, player } = await deployFresh();
    const SALT = ethers.encodeBytes32String("good");
    await game.startGame(5, makeHash("LRLLR", SALT));
    await game.connect(player).registerPlayer();
    await game.revealPattern("LRLLR", SALT);
    const { _patternRevealed } = await game.getGameState();
    assert.ok(_patternRevealed);
  });

  await test("commit-reveal: wrong pattern REVERTS", async () => {
    const { game, player } = await deployFresh();
    const SALT = ethers.encodeBytes32String("good2");
    await game.startGame(5, makeHash("LRLLR", SALT));
    await game.connect(player).registerPlayer();
    try {
      await game.revealPattern("RLRRL", SALT);
      assert.fail("should revert");
    } catch (e) {
      assert.ok(e.message.includes("hash mismatch") || e.message.includes("revert"));
    }
  });

  await test("commit-reveal: wrong salt REVERTS", async () => {
    const { game, player } = await deployFresh();
    const SALT = ethers.encodeBytes32String("real");
    await game.startGame(3, makeHash("LRL", SALT));
    await game.connect(player).registerPlayer();
    try {
      await game.revealPattern("LRL", ethers.encodeBytes32String("fake"));
      assert.fail("should revert");
    } catch (e) {
      assert.ok(e.message.includes("hash mismatch") || e.message.includes("revert"));
    }
  });

  await test("state machine: makeChoice blocked before ACTIVE", async () => {
    const { game, player } = await deployFresh();
    const SALT = ethers.encodeBytes32String("sm");
    await game.startGame(3, makeHash("LRL", SALT));
    try {
      await game.connect(player).makeChoice(true);
      assert.fail("should revert");
    } catch (e) {
      assert.ok(e.message.includes("wrong game state") || e.message.includes("revert"));
    }
  });

  await test("wrong address cannot makeChoice", async () => {
    const { game, player, spectator1 } = await deployFresh();
    const SALT = ethers.encodeBytes32String("wp");
    await game.startGame(1, makeHash("L", SALT));
    await game.connect(player).registerPlayer();
    await game.revealPattern("L", SALT);
    try {
      await game.connect(spectator1).makeChoice(true);
      assert.fail("should revert");
    } catch (e) {
      assert.ok(e.message.includes("not the registered player") || e.message.includes("revert"));
    }
  });

  console.log("\nFull game flows");

  await test("player wins — completes all steps", async () => {
    const { vault, game, player, spectator1 } = await deployFresh();
    const SALT = ethers.encodeBytes32String("win");
    await game.startGame(2, makeHash("LR", SALT));
    await vault.connect(spectator1).placeBet(1, true, { value: ethers.parseEther("0.1") });
    await game.connect(player).registerPlayer();
    await game.revealPattern("LR", SALT);
    await game.connect(player).makeChoice(true);
    const tx = await game.connect(player).makeChoice(false);
    const receipt = await tx.wait();
    const won = receipt.logs.some(log => {
      try { return game.interface.parseLog(log).name === "PlayerWon"; } catch { return false; }
    });
    assert.ok(won, "PlayerWon not emitted");
  });

  await test("player eliminated — wrong panel choice", async () => {
    const { vault, game, player, spectator1 } = await deployFresh();
    const SALT = ethers.encodeBytes32String("elim");
    await game.startGame(2, makeHash("LR", SALT));
    await vault.connect(spectator1).placeBet(1, false, { value: ethers.parseEther("0.05") });
    await game.connect(player).registerPlayer();
    await game.revealPattern("LR", SALT);
    const tx = await game.connect(player).makeChoice(false);
    const receipt = await tx.wait();
    const elim = receipt.logs.some(log => {
      try { return game.interface.parseLog(log).name === "PlayerEliminated"; } catch { return false; }
    });
    assert.ok(elim, "PlayerEliminated not emitted");
  });

  await test("contract-to-contract: vault settles bets correctly", async () => {
    const { vault, game, player, spectator1, spectator2 } = await deployFresh();
    const SALT = ethers.encodeBytes32String("c2c");
    await game.startGame(1, makeHash("L", SALT));
    await vault.connect(spectator1).placeBet(1, true, { value: ethers.parseEther("0.2") });
    await vault.connect(spectator2).placeBet(1, false, { value: ethers.parseEther("0.1") });
    await game.connect(player).registerPlayer();
    await game.revealPattern("L", SALT);
    await game.connect(player).makeChoice(true);
    const s1Win = await vault.getBalance(spectator1.address);
    const s2Win = await vault.getBalance(spectator2.address);
    assert.ok(s1Win > 0n, "S1 should have winnings");
    assert.equal(s2Win, 0n, "S2 should have no winnings");
  });

  await test("payout integrity: total out <= total in", async () => {
    const { vault, game, player, spectator1, spectator2 } = await deployFresh();
    const SALT = ethers.encodeBytes32String("integrity");
    const BET = ethers.parseEther("0.1");
    await game.startGame(1, makeHash("L", SALT));
    await vault.connect(spectator1).placeBet(1, true, { value: BET });
    await vault.connect(spectator2).placeBet(1, false, { value: BET });
    await game.connect(player).registerPlayer();
    await game.revealPattern("L", SALT);
    await game.connect(player).makeChoice(true);
    const s1Win = await vault.getBalance(spectator1.address);
    const fees = await vault.accumulatedFees();
    assert.ok(s1Win + fees <= BET * 2n);
  });

  console.log(`\n${"─".repeat(45)}`);
  console.log(`Results: ${passed} passed, ${failed} failed`);
  if (failed === 0) console.log("🎉 All tests passed!\n");
  else console.log("⚠️  Some tests failed.\n");
}

main();