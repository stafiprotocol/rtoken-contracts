import "@nomiclabs/hardhat-etherscan";
import "@nomiclabs/hardhat-waffle";
import {HardhatUserConfig, HttpNetworkUserConfig} from 'hardhat/types';
import 'hardhat-deploy';
import dotenv from "dotenv";
import yargs from "yargs";

const argv = yargs
    .option("network", {
        type: "string",
        default: "hardhat",
    })
    .help(false)
    .version(false).argv;

dotenv.config();
const { INFURA_KEY, MNEMONIC, ETHERSCAN_API_KEY, PK} = process.env;

const DEFAULT_MNEMONIC =
    "garlic path pool various surface pitch put near dutch strong whisper letter";

const sharedNetworkConfig: HttpNetworkUserConfig = {};
if (PK) {
    sharedNetworkConfig.accounts = [PK];
} else {
    sharedNetworkConfig.accounts = {
        mnemonic: MNEMONIC || DEFAULT_MNEMONIC,
    };
}

if (["mainnet", "rinkeby", "kovan", "goerli"].includes(argv.network) && INFURA_KEY === undefined) {
    throw new Error(
        `Could not find Infura key in env, unable to connect to network ${argv.network}`,
    );
}

const userConfig: HardhatUserConfig = {
    solidity: {
        compilers: [
            {version: "0.7.6"},
        ]
    },
    networks: {
        hardhat: {
            allowUnlimitedContractSize: true,
            blockGasLimit: 100000000,
            gas: 100000000
        },
        mainnet: {
            ...sharedNetworkConfig,
            url: `https://mainnet.infura.io/v3/${INFURA_KEY}`,
        },
        xdai: {
            ...sharedNetworkConfig,
            url: "https://xdai.poanetwork.dev",
        },
        ewc: {
            ...sharedNetworkConfig,
            url: `https://rpc.energyweb.org`,
        },
        rinkeby: {
            ...sharedNetworkConfig,
            url: `https://rinkeby.infura.io/v3/${INFURA_KEY}`,
        },
        goerli: {
            ...sharedNetworkConfig,
            url: `https://goerli.infura.io/v3/${INFURA_KEY}`,
        },
        kovan: {
            ...sharedNetworkConfig,
            url: `https://kovan.infura.io/v3/${INFURA_KEY}`,
        },
        volta: {
            ...sharedNetworkConfig,
            url: `https://volta-rpc.energyweb.org`,
        },
    },
    namedAccounts: {
        deployer: 0,
    },
    paths: {
        sources: 'contracts',
        deploy: 'src/deploy',
    },
    etherscan: {
        apiKey: ETHERSCAN_API_KEY,
    },
};
export default userConfig
