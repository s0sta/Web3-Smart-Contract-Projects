/* ============================================================
   Rahala dApp — configuration
   ============================================================ */

window.APP_CONFIG = {
  // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
  accountsAddress: "0x084353D5F680651deDa34073AF768E014E912A6E",
  aedsAddress: "0xdc62a2c3715139154b67A9F2261eFd47EA84Af22",
  usdAddress: "0x20b6cc6424867aA1639dB38C4433D01b21F9cd2c",
  complianceAddress: "0xf9626157607595E87b8A8b0A3b5802D9Be29DF31",
  oracleAddress: "0xE52322144936d7Da3234380fc7916DbD04E1B1ed",
  treasuryAddress: "0x359022603109Ac4AAaf4273031Afe8F10000ec6D",
  fxAddress: "0xa8C854E56C542Ce093cAE592A6AD2a0a46543c2b",
  escrowAddress: "0xb07c5CddDc08cBAe2E939eE20cd678a61D80085b",
  invoicesAddress: "0x3dc1F621f8a6D089F4C6583009dC6bc7f44d4896",
  settlementAddress: "0xcA7B23e0F047B9E8E32f2cc4CdaaCeb6858EA238",
  disputesAddress: "0xe5C9Fe934bc67740691b120199B406F27ee14706",
  governorAddress: "0x2Db75dB95Df2D0299283C5e3B2b3e9dBbE34f768",

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

  github: "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/22-rahala-payments",
  site: "https://s0sta.com/rahala",
};
