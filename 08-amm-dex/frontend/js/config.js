/* ============================================================
   AMM DEX dApp — configuration
   1. Deploy the AMM (see frontend/README.md) and paste the router
      address below, or set it at runtime from the Settings button.
   2. If you upload api/config.php, its routerAddress overrides
      this file at load time.
   ============================================================ */

window.APP_CONFIG = {
  // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
  routerAddress: "0xD7C530a1025A70e1932A1554932B35317496F819",

  // The two pool tokens (the app auto-discovers the pair via the factory).
  tokenA: "0xeeAa0E19Cc0734A45f99D54Ef034a3F7F2b37d3c", // GLD
  tokenB: "0x2Ea88C2c86c835551a00A605A4966Ba0d755De9e", // USD

  // Chain the app opens on by default (Sepolia testnet recommended).
  defaultChainId: 11155111,

  chains: {
    1: {
      name: "Ethereum Mainnet",
      short: "mainnet",
      rpc: "https://ethereum-rpc.publicnode.com",
      explorer: "https://etherscan.io",
      currency: "ETH",
    },
    11155111: {
      name: "Sepolia Testnet",
      short: "sepolia",
      rpc: "https://ethereum-sepolia-rpc.publicnode.com",
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

  // Blocks the activity feed looks back over (Sepolia ≈ 5 days).
  eventLookbackBlocks: 50000,

  // Links shown in the footer.
  github: "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/08-amm-dex",
  site: "https://dex.s0sta.com",
};
