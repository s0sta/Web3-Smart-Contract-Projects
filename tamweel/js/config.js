/* ============================================================
   Tamweel dApp — configuration
   ============================================================ */

window.APP_CONFIG = {
  // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
  vaultAddress: "0x8F05B5167decaD8266f01C11f333AAAA475C19bD",
  complianceAddress: "0x01703c2d627E3910a6683ec1E25F5a804198E481",
  oracleAddress: "0x3839347675d04CDd16B7272E3cd5DB96208ae85C",
  rateModelAddress: "0x82F91958D237D24d9DB1cBA20d9fb72f542B3220",
  marketsAddress: "0x55382486f607AfdF4c1B991Cf47c00d2208FcE6F",
  loansAddress: "0x519feCE71D6318996A66f5fC677E13eF160189F0",
  collateralAddress: "0xDbDc9B992af18d1Cd63A1E30F9B1Cd50bA30Cc81",
  insuranceAddress: "0x5c06e811c602c1a268b7cd8b6c6726661d8021b2",
  governorAddress: "0x0e5fcdfce304d74f090347453c65bbdb973437f7",
  stableAddress: "0x75a3CE6217e581d0B8F03Ad32b82E3F0b973d241",
  marketId: 0,

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

  github: "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/20-tamweel-credit",
  site: "https://s0sta.com/tamweel",
};
