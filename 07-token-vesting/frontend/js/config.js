/* ============================================================
   TokenVesting dApp — configuration
   1. Deploy the contract (see frontend/README.md) and paste the
      address below, or set it at runtime from the Settings button.
   2. If you upload api/config.php, its vestingAddress overrides
      this file at load time.
   ============================================================ */

window.APP_CONFIG = {
  // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
  vestingAddress: "0xCf406a9b6EF721B38421eFd9860Af921E765B935",

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
  github: "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/07-token-vesting",
  site: "https://vesting.s0sta.com",
};
