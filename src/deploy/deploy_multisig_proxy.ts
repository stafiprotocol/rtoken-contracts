import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const proxyTo = "0xbE91E35F02134df33763BfEA8D00fA22901e0cA8"
const data = "0x"

// deployed on remix, change to your own proxyAdminContract before deploying
const proxyAdminContract = "0xBf996BFe7a62ab39130281eC1062eDbEC88B708d"

const deploy: DeployFunction = async function (
    hre: HardhatRuntimeEnvironment,
) {
    const { deployments, getNamedAccounts } = hre;
    const { deployer } = await getNamedAccounts();
    const { deploy } = deployments;

    await deploy("MultisigProxy", {
        from: deployer,
        args: [proxyTo, proxyAdminContract, data],
        log: true,
        deterministicDeployment: true,
    });
};

deploy.tags = ['MultisigProxy']
export default deploy;
