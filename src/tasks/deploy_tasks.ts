import "hardhat-deploy";
import "@nomiclabs/hardhat-ethers";
import { task } from "hardhat/config";

task("deploy-contracts", "Deploys Multi contracts")
  .setAction(async (_, hre) => {
    await hre.run("deploy")
  });

export { }
