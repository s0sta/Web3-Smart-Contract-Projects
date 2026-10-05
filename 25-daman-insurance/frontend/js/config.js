/* ============================================================
   Daman dApp — configuration
   ============================================================ */

window.APP_CONFIG = {
  // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
  registryAddress: "0x0476a7b394C8325B810790B765bDEb909dc71cA9",
  oracleAddress: "0x36c6a1269983B71C976ff3Cc82248e3E16bE0000",
  pricingAddress: "0xBCF769cC83C6d62d181dA437bECDA8281be90Bca",
  treasuryAddress: "0xA2321f5F19a433e7a0d5EC233D73f4dc0c1Ae736",
  premiumsAddress: "0x64E5923B2B583eD53a4cecCa2e029dF3136baEE7",
  policiesAddress: "0x44238fcb193ad6F1623e5522071aA829210FA7Ee",
  claimsAddress: "0x7851B3b443a4a51841A332Cc3f66927352e0d1e6",
  parametricAddress: "0xc1A72d617429C50A14F451a8635B19AABA41A29A",
  reinsuranceAddress: "0x9E4B2883D55EdC3E2f7531F10De27E9c6D6b14DA",
  surplusAddress: "0xCfc17095e015e4bFAfF16942B237f9d099938443",
  governorAddress: "0x3a4e6B7c21A6f9a3E1EbA685B2A809E9c2c338E4",
  aedsAddress: "0x1F333e856D8f404da17411d5DdC57D11Fb7801Ca",
  conditionId: 0,

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

  github: "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/25-daman-insurance",
  site: "https://s0sta.com/daman",
};
