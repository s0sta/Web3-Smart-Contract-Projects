/* ============================================================
   Ataa dApp — configuration
   ============================================================ */

window.APP_CONFIG = {
  // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
  registryAddress: "0x1e64F582DA7b9d869c4AbDE9cc5155BF3B8e30cf",
  oracleAddress: "0x6982639F40Cebd593a9bC7325985696a28E9D7A6",
  zakatAddress: "0x8f550F2a0B02caB48fC66CF4472ad003Be856330",
  vaultAddress: "0x5BB057139Bf81822Db668cF3E14fAd7A626096A8",
  donationsAddress: "0x6141632F653BF311a96bdb6875E3A0D7866587d1",
  allocationsAddress: "0xE6a6299991B74548feF9E43F13aB5554fC654217",
  emergencyAddress: "0x72F08d89224D4B83728e7264C5E346afe7Fa9c0b",
  sponsorshipsAddress: "0xA9408f4CE22e76d0f3742F011aaD2C6b641BF9E5",
  governorAddress: "0x0503B66b0f897394A19de7CD6adEDD6880aE65A3",
  aedsAddress: "0xAcA41b03aD8D9A6d22DDB98a13Fb730744B9025D",

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

  github: "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/26-ataa-giving",
  site: "https://s0sta.com/ataa",
};
