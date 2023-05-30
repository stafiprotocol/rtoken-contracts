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
      accounts: [
        '7c12708ee2f423e86d3b77e6bef12907ca61b2d97a7195f93c1137dc08098b74', // superuser
        '13d28b99efc64e66d4bb549f2dba1324305d47629b2141f1c16163f6ff6a2206', // trustnode
        '45a690ae0fab855d60f592b2cd561a730a1d3ab60e138c5366b9e27778c066d9', // supernode
        '9e078940152584a642aaed17ebb97509274f874e176695de947ade3a1d8fe353', // 
        'b7d6bef9fec45408c5d6c7f3182ab409f0774549481179ee627e87b8ec43980f', // 
        'cf9021015de4fe7559b981e098f46659b7f9a9dc28e89b7f554936c7aadaf822', // 
      ],
    },
    ethMainnet: {
      url: `https://eth-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_API_KEY}`,
    },
    goerli: {
      url: `https://goerli.infura.io/v3/${process.env.INFURA_KEY}`,
    },
    bscmainnet: {
      url: `https://rpc.ankr.com/bsc`,
    },
    bsctestnet: {
      url: `https://rpc.ankr.com/bsc_testnet_chapel`,
    },
    polygonMainnet: {
      url: `https://rpc.ankr.com/polygon`,
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

