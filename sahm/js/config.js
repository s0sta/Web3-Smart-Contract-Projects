/* ============================================================
   Sahm dApp — configuration
   ============================================================ */

window.APP_CONFIG = {
  // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
  collateralAddress: "0xb438AbC481c3888C83fcDcE7143ED087F724B77b",
  complianceAddress: "0x3EEc7cf953D6cEB22cADd17AB75F0436B333a38E",
  oracleAddress: "0x26BA70d31685e437E1B2eda07CB6951BFC88DCeF",
  treasuryAddress: "0x87F497a7C00B7883543a0bC0408Fa9fe3572a056",
  riskAddress: "0xAc6691DaE49527C44eBD1b46cf81ca8020Bf7af6",
  orderBookAddress: "0x7ce8C02eA7abaC12C9719Ee57618D4f55852f8fd",
  ammAddress: "0xAE3f687F309b65C779B021640B913996b097d896",
  marginAddress: "0xCF8F74215F512aB1D1d2a2635695066870E6cc63",
  insuranceAddress: "0x5507B55d6fD3C041d7D11e6148D804e0a1BEB285",
  governorAddress: "0x87B60481a1D59aEA2C1f4E3D77805a3e712b25fE",
  stableAddress: "0x6060A2d68d961f82A8796CE3ba6E0Fa3f0E93F0a",
  poolId: 0,

  defaultChainId: 11155111,

  chains: {
    1: {
      name: "Ethereum Mainnet",
      short: "mainnet",
      rpc: "https://ethereum-rpc.publicnode.com",
      rpcFallbacks: ["https://eth.llamarpc.com"],
      explorer: "https://etherscan.io",
      currency: "ETH",
    },
    11155111: {
      name: "Sepolia Testnet",
      short: "sepolia",
      rpc: "https://ethereum-sepolia-rpc.publicnode.com",
      rpcFallbacks: ["https://1rpc.io/sepolia"],
      explorer: "https://sepolia.etherscan.io",
      currency: "ETH",
    },
    31337: {
      name: "Local (Anvil)",
      short: "anvil",
      rpc: "http://127.0.0.1:8545",
      explorer: null,
      currency: "ETH",
    },
  },

  github: "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/21-sahm-exchange",
  site: "https://s0sta.com/sahm",
};
