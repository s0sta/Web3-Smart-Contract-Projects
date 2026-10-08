/* ============================================================
   Taqa dApp — configuration
   ============================================================ */

window.APP_CONFIG = {
  // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
  registryAddress: "0xc183fA1628d408D63b754aA9F5A8bAFF0167fb25",
  oracleAddress: "0xb7278e32bf69f8bF65fdEFd1c0F78416eC1E98D9",
  metersAddress: "0x8C1bBa56eF89b51EcF44B33f84D8FA06C88120eA",
  certificatesAddress: "0xb612873217D0DcC41a08F74FC8dB4Ebf2dF8A8d5",
  carbonAddress: "0xC265CF8bA0c68d9964c9e563f583E0FD7850bEb7",
  treasuryAddress: "0xeb78F1F5c27F734eC8E70492D776663aE34B194a",
  marketAddress: "0x9F368Fd2bAd175287d3c56568e38A5ecd23001Ad",
  p2pAddress: "0xd385d04942badcE1638FF16EF8519226DFe26c12",
  retirementAddress: "0x44837CDbB1dcb2C044E8586863d34B0C0281f531",
  complianceAddress: "0xbA948e8c8E42b23C7cAB2f29940F8E93692C0E50",
  governorAddress: "0x67a5187eb05EDbe62f235B13bc6aB8bCCF15F7Fd",
  aedsAddress: "0xbF7A13e9Fe82Adb11ff5b1202b1510D285A73BF1",

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

  github: "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/26-taqa-energy",
  site: "https://s0sta.com/taqa",
};
