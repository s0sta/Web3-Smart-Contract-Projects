/* ============================================================
   Ataa dApp — configuration
   ============================================================ */

window.APP_CONFIG = {
  // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
  // Settlement currency: AtaaStable (SAR-S) — pegged to the Saudi Riyal.
  registryAddress: "0xeE9fd5f7b8Eb2250963F3d948fEcfc62D5A02018",
  oracleAddress: "0xA367b6403dbFbD37B4A7Ca9c899DF6CF6dA7e87B",
  zakatAddress: "0x3f998976D1aB813412147Ed172938d86f85A9B83",
  vaultAddress: "0x68De795501811130F7D319C1237CbC879C241eA9",
  donationsAddress: "0x548a3B476B560953fCb5f428Cfa0ABd87e2df088",
  allocationsAddress: "0x657f702d63aa521e69eF882797D1F258471Ddc5b",
  emergencyAddress: "0xC232C7805bc4f6000e72261e422A5fC89559b7F0",
  sponsorshipsAddress: "0xebDf721Fd99B65C6338A9ce583c1Fc539dD81f0D",
  governorAddress: "0xb8282ABE0d9a2b6d113C1bF555DBDA6Cf4A56b27",
  aedsAddress: "0xbCe8783ED240814a6C80D43be8909Fb3Dd6D9aC5",

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
