/* ============================================================
   CrowdFund dApp — configuration
   1. Deploy the factory (see frontend/README.md) and paste the
      address below, or set it at runtime from the Settings button.
   2. If you upload api/config.php, its factoryAddress overrides
      this file at load time.
   ============================================================ */

window.APP_CONFIG = {
  // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
  factoryAddress: "0x49Ed445AB73b0397B8946c6BCDCa4bFcF04C9FdB",

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
  github: "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/02-crowdfunding",
  site: "https://crowdfund.s0sta.com",
};
