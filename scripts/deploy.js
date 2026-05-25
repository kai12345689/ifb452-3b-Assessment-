const hre = require("hardhat");
const ethers = hre.ethers;
const fs = require("fs");
const path = require("path");

async function main() {
  const [frontMan] = await ethers.getSigners();

  console.log("Deployer:", frontMan.address);
  console.log("Balance: ", ethers.formatEther(await ethers.provider.getBalance(frontMan.address)), "ETH\n");

  // Deploy BettingVault
  console.log("Deploying BettingVault (5% house fee)...");
  const VaultFactory = await ethers.getContractFactory("BettingVault");
  const vault = await VaultFactory.deploy(5);
  await vault.waitForDeployment();
  const vaultAddr = await vault.getAddress();
  console.log("BettingVault deployed at:", vaultAddr);

  // Deploy GlassBridgeGame
  console.log("\nDeploying GlassBridgeGame...");
  const GameFactory = await ethers.getContractFactory("GlassBridgeGame");
  const game = await GameFactory.deploy(vaultAddr);
  await game.waitForDeployment();
  const gameAddr = await game.getAddress();
  console.log("GlassBridgeGame deployed at:", gameAddr);

  // Link contracts
  console.log("\nLinking contracts...");
  const tx = await vault.setGameContract(gameAddr);
  await tx.wait();
  console.log("Linked! BettingVault now only accepts settleStep from GlassBridgeGame.");

  // Save addresses
  const deployment = { BettingVault: vaultAddr, GlassBridgeGame: gameAddr };
  fs.writeFileSync("deployment.json", JSON.stringify(deployment, null, 2));
  console.log("\n✅ Done! Saved to deployment.json");
}

main().catch(console.error);