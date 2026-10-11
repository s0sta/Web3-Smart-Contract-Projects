/* ============================================================
   Shifa dApp — configuration
   ============================================================ */

window.APP_CONFIG = {
  // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
  registryAddress: "0xB4A139e894c752765d0c2FD69CBE538f1013cA20",
  consentAddress: "0xEB7Eb23657E2F6B5b44A857D2B099d232aBD03e5",
  recordsAddress: "0xfBE9c9b15c23CebFde319158144cc1B33400EBa7",
  prescriptionsAddress: "0x8453D2c76B9A4D248C9FE542Ab3666e11054CEf0",
  emergencyAddress: "0x3770f946141d6e29abdACb44ae447714Bb94605b",
  appointmentsAddress: "0x259dE4db26F04Aaf990055c0116920b4eDeb5925",
  treasuryAddress: "0x0D94Fe8F3b5dC11d78580CB3B0932d28E37106a5",
  insuranceAddress: "0x9138b42dda93622933642Ef02a5ce771e473f697",
  paymentsAddress: "0x281C8ECb83d19E271c47917022dbbf909b43353e",
  reputationAddress: "0x57EC0f51DAb9F8Fd89073A541EA61708408C99e4",
  governorAddress: "0x5803582f7Da180DD954596de73e06e960014d612",
  sarAddress: "0xcDcdAe912bb7F480Bf052f6e1b59dC380Af64C9d",

  defaultChainId: 11155111,

  chains: {
    11155111: {
      name: "Sepolia Testnet",
      short: "sepolia",
      rpc: "https://ethereum-sepolia-rpc.publicnode.com",
      rpcFallbacks: ["https://sepolia.gateway.tenderly.co"],
      explorer: "https://sepolia.etherscan.io",
      currency: "ETH",
    },
    1: {
      name: "Ethereum Mainnet",
      short: "mainnet",
      rpc: "https://ethereum-rpc.publicnode.com",
      rpcFallbacks: ["https://eth.llamarpc.com"],
      explorer: "https://etherscan.io",
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

  github: "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/28-shifa-healthcare",
  site: "https://s0sta.com/Web3-Smart-Contract-Projects/shifa",
};
