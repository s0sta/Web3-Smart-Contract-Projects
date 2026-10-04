/* ============================================================
   NovaToken dApp — configuration
   ------------------------------------------------------------
   1. Deploy NovaToken (see frontend/README.md) and paste the
      address in `tokenAddress` below, OR set it at runtime from
      the "Settings" button (saved in your browser).
   2. If you upload `api/config.php`, its tokenAddress overrides
      this file at load time (handy on Hostinger).
   ============================================================ */

window.APP_CONFIG = {
  // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
  tokenAddress: "0x26b420683E6F6Df39CFceBd7C5bB78B7459b8B62",

  // Chain the app opens on by default (Sepolia testnet recommended).
  defaultChainId: 11155111,

  // Network definitions used for switching, badges and explorers.
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

  // How many blocks back the activity feed looks (Sepolia ≈ 5 days).
  eventLookbackBlocks: 50000,

  // GitHub link shown in the footer.
  github: "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/01-erc20-token",
};
