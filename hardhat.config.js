require("hardhat-contract-sizer")
require("@nomiclabs/hardhat-ethers");
require("@nomiclabs/hardhat-web3");
require("@nomiclabs/hardhat-etherscan");

// set proxy
const { ProxyAgent, setGlobalDispatcher } = require("undici");
const proxyAgent = new ProxyAgent('http://127.0.0.1:7890'); // change to yours
setGlobalDispatcher(proxyAgent)

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.7.6",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  networks: {
    hardhat: {
    },
    local: {
      url: 'http://127.0.0.1:8545',
    },
    ethMainnet: {
      url: `https://rpc.ankr.com/eth`,
    },
    goerli: {
      url: `https://rpc.ankr.com/eth_goerli`,
    },
    bscmainnet: {
      url: `https://rpc.ankr.com/bsc`,
    },
    bsctestnet: {
      url: `https://rpc.ankr.com/bsc_testnet_chapel`,
    },
    polygonMainnet: {
      url: `https://rpc.ankr.com/polygon`,
    },
    arbitrumMainnet: {
      url: `https://rpc.ankr.com/arbitrum`,
    }
  },
  defaultNetwork: "hardhat",
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  },
  contractSizer: {
    alphaSort: true,
    runOnCompile: false,
    disambiguatePaths: false,
  },
  etherscan: {
    // Your API key for Etherscan
    // Obtain one at https://etherscan.io/
    apiKey: `${process.env.ETHERSCAN_KEY}`
  }
};

