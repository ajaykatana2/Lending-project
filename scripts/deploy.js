const { ethers } = require("hardhat");

async function main() {
  console.log("🚀 Starting deployment of Lending Project...");
  
  // Get the deployer account
  const [deployer] = await ethers.getSigners(); 
  
  console.log("📝 Deploying contracts with the account:", deployer.address);
  console.log("💰 Account balance:", (await deployer.provider.getBalance(deployer.address)).toString());
  
  // Get the contract factory
  const LendingProject = await ethers.getContractFactory("Project");
  
  console.log("🔨 Deploying Lending Project contract...");
  
  // Deploy the contract
  const lendingProject = await LendingProject.deploy();
  
  // Wait for the contract to be deployed
  await lendingProject.waitForDeployment();
  
  const contractAddress = await lendingProject.getAddress();
  
  console.log("✅ Lending Project deployed successfully!");
  console.log("📍 Contract address:", contractAddress);
  console.log("🔗 Transaction hash:", lendingProject.deploymentTransaction().hash);
  
  // Display contract details
  console.log("\n📊 Contract Details:");
  console.log("- Interest Rate:", await lendingProject.INTEREST_RATE(), "basis points (5%)");
  console.log("- Collateral Ratio:", await lendingProject.COLLATERAL_RATIO(), "basis points (150%)");
  console.log("- Liquidation Threshold:", await lendingProject.LIQUIDATION_THRESHOLD(), "basis points (120%)");
  
  // Verify the contract on Core Testnet 2 explorer
  if (hre.network.name === "core_testnet2") {
    console.log("\n🔍 Waiting for block confirmations...");
    await lendingProject.deploymentTransaction().wait(6);
    
    console.log("🔍 Verifying contract on Core Testnet 2 explorer...");
    try {
      await hre.run("verify:verify", {
        address: contractAddress,
        constructorArguments: [],
      });
      console.log("✅ Contract verified successfully!");
    } catch (error) {
      console.log("❌ Contract verification failed:", error.message);
    }
  }
  
  console.log("\n🎉 Deployment completed successfully!");
  console.log("📋 Contract Functions Available:");
  console.log("   - deposit() - Deposit ETH to earn interest");
  console.log("   - borrow(uint256) - Borrow ETH with collateral");
  console.log("   - repayLoan(uint256) - Repay loan and retrieve collateral");
  console.log("   - withdraw(uint256) - Withdraw deposited funds");
  console.log("   - liquidate(address, uint256) - Liquidate undercollateralized loans");
  
  console.log("\n🌐 Core Testnet 2 Explorer:");
  console.log(`   https://scan.test2.btcs.network/address/${contractAddress}`);
  
  // Save deployment info to a file
  const deploymentInfo = {
    network: hre.network.name,
    contractAddress: contractAddress,
    deployer: deployer.address,
    transactionHash: lendingProject.deploymentTransaction().hash,
    timestamp: new Date().toISOString(),
    blockNumber: lendingProject.deploymentTransaction().blockNumber,
  };
  
  const fs = require("fs");
  const path = require("path");
  
  // Create deployments directory if it doesn't exist
  const deploymentsDir = path.join(__dirname, "../deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir);
  }
  
  // Save deployment info
  const deploymentFile = path.join(deploymentsDir, `${hre.network.name}.json`);
  fs.writeFileSync(deploymentFile, JSON.stringify(deploymentInfo, null, 2));
  
  console.log(`📁 Deployment info saved to: ${deploymentFile}`);
}

// Handle errors
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Deployment failed:", error);
    process.exit(1);
  });

