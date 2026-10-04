/* ============================================================
   Silsila dApp — configuration
   ============================================================ */

window.APP_CONFIG = {
  // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
  registryAddress: "0x62D09186787FE0af9F34724022DB26795F10812c",
  complianceAddress: "0x0961407589B2495f2CE6c23000291eB4eDB16CB0",
  ordersAddress: "0x98027C13e5423F8f5DD1D1ab894d4d036D36711B",
  shipmentsAddress: "0xf5f1266e8a632c942A7011A9A7a5B7A22B42A1D7",
  qualityAddress: "0x92dB2c3EBEb4f62B0B9eBB9DAf6A59124Ca63706",
  paymentsAddress: "0xda16403Bb071b978f38E540F872c6A8D0045e994",
  cargoAddress: "0xe461426560892f01Cf415ad3C4d30222aE4bdc88",
  reputationAddress: "0xD56e2668267F60c3D2a9bEe76BFdC80CE2112AB3",
  treasuryAddress: "0x65599Ef61845C0819EA4B4b1Df9a791b67eEAd9d",
  oracleAddress: "0x0a84Eca9307CEeaBDfe1857829000713081b03F6",
  governorAddress: "0xc7788564809c54dfd8bffd1e9c196620bc10f629",
  aedsAddress: "0x4109B4b0C5f1178Ad31a24BF04d848b7758B1904",

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

  github: "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/24-silsila-supplychain",
  site: "https://s0sta.com/silsila",
};
