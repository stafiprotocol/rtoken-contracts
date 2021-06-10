import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const owners = ["0xBd39f5936969828eD9315220659cD11129071814", "0xBca9567A9e8D5F6F58C419d32aF6190F74C880e6"]
const threshold = 1
const AddressZero = "0x0000000000000000000000000000000000000000"
const data = "0x"

const deploy: DeployFunction = async function (
    hre: HardhatRuntimeEnvironment,
) {
    const { deployments, getNamedAccounts } = hre;
    const { deployer } = await getNamedAccounts();
    const { deploy } = deployments;

    await deploy("Multisig", {
        from: deployer,
        args: [owners, threshold, AddressZero, data],
        log: true,
        deterministicDeployment: true,
    });
};

deploy.tags = ['Multisig']
export default deploy;
