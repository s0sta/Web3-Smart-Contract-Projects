/* ============================================================
   Waqf Endowment dApp — configuration
   ============================================================ */

window.APP_CONFIG = {
  // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
  vaultAddress: "0x3dc6d47de5f14f562b4bee02417d2fa51cab1c19",
  governorAddress: "0xa2def9668265bca1b6ad0b928f6aa00658d18c15",
  registryAddress: "0x368923bf9dbd5a15f67626154104f4b2d70f6555",
  stableAddress: "0x81fc34aa5568aaf97b116048473411f532bd83b9",

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

  eventLookbackBlocks: 50000,
  github: "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/13-waqf-endowment",
  site: "https://s0sta.com/waqf",
};
