/* ============================================================
   Mawarid dApp — configuration
   ============================================================ */

window.APP_CONFIG = {
  // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
  registryAddress: "0x7A688e184ab92b97a0062fA0A752E07974627C50",
  complianceAddress: "0x7fF2db78efc49f13D757f654a2c2fe6692E49098",
  sharesAddress: "0xa136455aad29Bb17720a9bFC54C8F6460464F8AF",
  primaryAddress: "0x5Dd2Bd4B6C364a5F427f6A70f611c795791847bd",
  secondaryAddress: "0x96BD1cD69A91Aa41961D4D8b1da56531c045d282",
  distributorAddress: "0x652f6a6F0E4B9E423B8952b56540c888c8AB451C",
  treasuryAddress: "0x313A0211d534A4731A4966341A2603daD176fA9E",
  insuranceAddress: "0x0066cc2579c91c303a0a93fceaa8e42fa8285253",
  governorAddress: "0x5e21174078b936d686227531ada530ddb1b22a4a",
  stableAddress: "0x8E1E1C99243525f99DD40102A05CF25020c8fED2",
  assetId: 0,

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

  github: "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/19-mawarid-rwa",
  site: "https://s0sta.com/mawarid",
};
