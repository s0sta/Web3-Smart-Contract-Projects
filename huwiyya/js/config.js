/* ============================================================
   Huwiyya dApp — configuration
   ============================================================ */

window.APP_CONFIG = {
  // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
  registryAddress: "0x77701d73b4615715f3767E5ca308EB07Eb0A8Ae9",
  schemasAddress: "0xd923B29B7521A0c637942BBaAB40d9ea1Fa2A9B8",
  treasuryAddress: "0x606C0E9ef77648aFb0C133fe2bA7AfE1e83172C5",
  credentialsAddress: "0xC31C903725F905cCe58D094De72C380c45d91F59",
  attestationsAddress: "0x58Cf0eD462c71D81bf445AE03ACe32e799189a73",
  reputationAddress: "0x3A3cE881070169DdA753420c69d86c7cBAB043D5",
  gatesAddress: "0x0a5F0084A14B77ae30044A22b670856148b2B8a5",
  recoveryAddress: "0xD5FA3cd4644Ea9A0695cec2f4310C37563D56779",
  governorAddress: "0xd773e313Bb69bc7d96f361Cf5F17FFbB18a64120",
  feeTokenAddress: "0x6381624072F624A549b2c7409b45c22FD0f3B1cC",
  schemaId: 0,

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

  github: "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/23-huwiyya-identity",
  site: "https://s0sta.com/huwiyya",
};
