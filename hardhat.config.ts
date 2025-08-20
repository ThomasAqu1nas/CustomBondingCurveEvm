import type { HardhatUserConfig } from "hardhat/config";

import hardhatToolboxMochaEthersPlugin from "@nomicfoundation/hardhat-toolbox-mocha-ethers";
import { configVariable } from "hardhat/config";
import hardhatKeystore from "@nomicfoundation/hardhat-keystore";

const config: HardhatUserConfig = {
  plugins: [hardhatToolboxMochaEthersPlugin, hardhatKeystore],
  paths: {
    artifacts: "./artifacts/hardhat",
    sources: "./contracts/src",
    cache: "./cache/hardhat",
  },
  solidity: {
    compilers: [
      {
        version: "0.8.28",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
      {
        version: "0.6.6",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
      {
        version: "0.5.16",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
    ],
    overrides: {
      "contracts/src/uniswap-v2/core/UniswapV2*.sol": {
        version: "0.5.16",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
      "contracts/src/uniswap-v2/core/libraries/**/*.sol": {
        version: "0.5.16",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
      "contracts/src/uniswap-v2/libraries/**/*.sol": {
        version: "0.5.16",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
      "contracts/src/uniswap-v2/periphery/UniswapV2Router*.sol": {
        version: "0.6.6",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
      "contracts/src/uniswap-v2/periphery/libraries/**/*.sol": {
        version: "0.6.6",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
      "contracts/src/core/**/*.sol": {
        version: "0.8.28",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
      "contracts/src/interfaces/**/*.sol": {
        version: "0.8.28",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
      "contracts/tests/**/*.sol": {
        version: "0.8.28",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
    },
  },
  networks: {
    hardhat: {
      type: "edr-simulated",
      forking: {
        url: configVariable("ALCHEMY_MAINNET_FORK_URL"),
        // blockNumber: 20400000, // опционально для детерминизма
      },
      mining: { auto: true, interval: 5000 },
      accounts: { accountsBalance: "0x3635C9ADC5DEA00000" }, // 1e21 wei ~ 1000 ETH на аккаунт
    },
    monad: {
      type: "http",
      url: configVariable("MONAD_TESTNET_RPC_URL"),
      accounts: [configVariable("MONAD_TESTNET_PRIVATE_KEY")],
      chainId: 10143,
    },
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1",
    },
    hardhatOp: {
      type: "edr-simulated",
      chainType: "op",
    },
    sepolia: {
      type: "http",
      chainType: "l1",
      url: configVariable("SEPOLIA_RPC_URL"),
      accounts: [configVariable("SEPOLIA_PRIVATE_KEY")],
    },
    localhost: {
      type: "http",
      url: "http://127.0.0.1:8545",
      chainId: 10144,
      accounts: [
        "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", //0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
        "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d", //0x70997970C51812dc3A010C7d01b50e0d17dc79C8
        "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a", //0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
        "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6", //0x90F79bf6EB2c4f870365E785982E1f101E93b906
      ],
    },
  },
};

export default config;
