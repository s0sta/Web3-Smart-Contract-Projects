/* ============================================================
   Estate Tokenization dApp — configuration
   ============================================================ */

window.APP_CONFIG = {
  // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
  registryAddress: "0x12dd8571779A707E931471c38D631D8542046180",
  // Companion contracts (the dApp resolves them from these addresses).
  distributorAddress: "0xc712C6ADb5c00D91AC42606E1956f910934B6D9a",
  stableAddress: "0x05cD5A021f0fEd5Cf3AC44845E31a81b5E3D42Ee",

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

  github: "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/12-realestate-tokenization",
  site: "https://s0sta.com/estate",
};
