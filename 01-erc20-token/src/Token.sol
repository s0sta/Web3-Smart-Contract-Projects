// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "./Ownable.sol";

/// @title NovaToken
/// @notice A complete ERC-20 token implemented from scratch: hard supply cap, owner minting
///         and burning, an emergency pause, and EIP-2612 gasless approvals (permit).
/// @dev Written without OpenZeppelin on purpose — see README "Production hardening" for what
///      to swap when deploying with real funds.
contract NovaToken is Ownable {
    /* ==================== METADATA ==================== */

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    /// @notice Hard supply cap. `mint` can never push `totalSupply` past this value.
    uint256 public constant MAX_SUPPLY = 100_000_000 * 1e18;

    /* ==================== ERC-20 STATE ==================== */

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /* ==================== CONTROL STATE ==================== */

    /// @notice While true, all token movement (transfer, mint, burn, permit) is frozen.
    bool public paused;

    /* ==================== EIP-2612 STATE ==================== */

    /// @notice Anti-replay counter, one per address, incremented by every `permit` call.
    mapping(address => uint256) public nonces;

    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private immutable CACHED_NAME_HASH;
    bytes32 private constant VERSION_HASH = keccak256(bytes("1"));

    /* ==================== EVENTS ==================== */

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    /* ==================== ERRORS ==================== */

    error InsufficientBalance(address account, uint256 balance, uint256 amount);
    error InsufficientAllowance(address spender, uint256 allowed, uint256 amount);
    error MaxSupplyExceeded(uint256 requested, uint256 cap);
    error TokenPaused();
    error PermitExpired(uint256 deadline);
    error InvalidPermitSignature();

    /* ==================== CONSTRUCTOR ==================== */

    /// @param name_ Token name (e.g. "NovaToken").
    /// @param symbol_ Token symbol (e.g. "NOVA").
    /// @param initialOwner Address that receives ownership.
    constructor(string memory name_, string memory symbol_, address initialOwner) Ownable(initialOwner) {
        name = name_;
        symbol = symbol_;
        CACHED_NAME_HASH = keccak256(bytes(name_));
    }

    /* ==================== ERC-20 CORE ==================== */

    /// @notice Moves `amount` tokens from `msg.sender` to `to`.
    /// @return Always true, matching the ERC-20 interface.
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Allows `spender` to move up to `amount` of `msg.sender`'s tokens.
    /// @return Always true, matching the ERC-20 interface.
    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @notice Moves `amount` tokens from `from` to `to`, spending `msg.sender`'s allowance.
    /// @dev An allowance of `type(uint256).max` is treated as "infinite" and never decreases.
    /// @return Always true, matching the ERC-20 interface.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance(msg.sender, allowed, amount);
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    /* ==================== MINT / BURN ==================== */

    /// @notice Mints `amount` new tokens to `to`. Owner only, never above `MAX_SUPPLY`.
    function mint(address to, uint256 amount) external onlyOwner {
        if (paused) revert TokenPaused();
        if (to == address(0)) revert ZeroAddress();
        if (totalSupply + amount > MAX_SUPPLY) revert MaxSupplyExceeded(totalSupply + amount, MAX_SUPPLY);
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
        emit Minted(to, amount);
    }

    /// @notice Destroys `amount` of the caller's own tokens.
    function burn(uint256 amount) external {
        if (paused) revert TokenPaused();
        _burn(msg.sender, amount);
    }

    /// @notice Destroys `amount` of `account`'s tokens, spending `msg.sender`'s allowance.
    function burnFrom(address account, uint256 amount) external {
        if (paused) revert TokenPaused();
        uint256 allowed = allowance[account][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance(msg.sender, allowed, amount);
            allowance[account][msg.sender] = allowed - amount;
        }
        _burn(account, amount);
    }

    /* ==================== EMERGENCY PAUSE ==================== */

    /// @notice Freezes all token movement. Owner only. Use during suspected exploits.
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Resumes token movement. Owner only.
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /* ==================== EIP-2612 PERMIT ==================== */

    /// @notice EIP-712 domain separator for this contract and chain.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, CACHED_NAME_HASH, VERSION_HASH, block.chainid, address(this))
        );
    }

    /// @notice Gasless approval: `owner` signs a permit off-chain and anyone may submit it.
    /// @dev The signature covers (owner, spender, value, nonce, deadline); the nonce makes
    ///      each signature single-use and the deadline stops old signatures from working.
    function permit(
        address owner_,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp > deadline) revert PermitExpired(deadline);
        if (paused) revert TokenPaused();

        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner_, spender, value, nonces[owner_]++, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        address signer = ecrecover(digest, v, r, s);

        if (signer != owner_ || signer == address(0)) revert InvalidPermitSignature();
        _approve(owner_, spender, value);
    }

    /* ==================== INTERNALS ==================== */

    function _transfer(address from, address to, uint256 amount) internal {
        if (paused) revert TokenPaused();
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        balanceOf[from] = fromBalance - amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _approve(address owner_, address spender, uint256 amount) internal {
        if (owner_ == address(0) || spender == address(0)) revert ZeroAddress();
        allowance[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function _burn(address account, uint256 amount) internal {
        uint256 accountBalance = balanceOf[account];
        if (accountBalance < amount) revert InsufficientBalance(account, accountBalance, amount);
        balanceOf[account] = accountBalance - amount;
        totalSupply -= amount;
        emit Transfer(account, address(0), amount);
        emit Burned(account, amount);
    }
}
