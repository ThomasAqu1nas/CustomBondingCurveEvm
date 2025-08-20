// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

/// @title SmthToken
/// @notice Fixed-supply ERC20-like token: the full supply is minted to the factory at deployment.
///         No further minting is allowed.
contract SmthToken is IERC20, IERC20Metadata, IERC20Errors, Context {
    string private _name;
    string private _symbol;
    uint8  private _decimals = 18;

    uint256 private _totalSupply;
    uint8 private _minted;
    address public factory;


    error SmthToken__AlreadyMinted();

    modifier MintOnce() {
        if (_minted != 0) revert SmthToken__AlreadyMinted();
        _minted = 255;
        _;
    }

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    modifier onlyFactory() {
        require(msg.sender == factory, "Only factory");
        _;
    }

    constructor(string memory name_, string memory symbol_, uint256 totalSupply_) {
        _name = name_;
        _symbol = symbol_;
        factory = msg.sender;
        _mint(factory, totalSupply_); // Mint full supply to the factory
    }

    // ---- Metadata ----
    function name() external view returns (string memory) { return _name; }
    function symbol() external view returns (string memory) { return _symbol; }
    function decimals() external view returns (uint8) { return _decimals; }

    // ---- ERC20 Views ----
    function totalSupply() external view returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view returns (uint256) { return _balances[account]; }
    function allowance(address owner, address spender) public view returns (uint256) { return _allowances[owner][spender]; }

    // ---- ERC20 Writes ----
    function approve(address spender, uint256 value) external returns (bool) {
        _approve(_msgSender(), spender, value);
        return true;
    }

    function transfer(address to, uint256 value) public returns (bool) {
        _transfer(_msgSender(), to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        _spendAllowance(from, _msgSender(), value);
        _transfer(from, to, value);
        return true;
    }

    // ---- Internals ----
    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to   == address(0)) revert ERC20InvalidReceiver(address(0));
        _update(from, to, value);
    }

    function _mint(address to, uint256 value) internal MintOnce {
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        _update(address(0), to, value);
    }

    function _update(address from, address to, uint256 value) internal {
        if (from == address(0)) {
            _totalSupply += value;
        } else {
            uint256 fb = _balances[from];
            if (fb < value) revert ERC20InsufficientBalance(from, fb, value);
            unchecked { _balances[from] = fb - value; }
        }

        if (to == address(0)) {
            unchecked { _totalSupply -= value; }
        } else {
            unchecked { _balances[to] += value; }
        }

        emit Transfer(from, to, value);
    }

    function _approve(address owner, address spender, uint256 value) internal { _approve(owner, spender, value, true); }

    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal {
        if (owner  == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender== address(0)) revert ERC20InvalidSpender(address(0));
        _allowances[owner][spender] = value;
        if (emitEvent) emit Approval(owner, spender, value);
    }

    function _spendAllowance(address owner, address spender, uint256 value) internal {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance < type(uint256).max) {
            if (currentAllowance < value) revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            unchecked { _approve(owner, spender, currentAllowance - value, false); }
        }
    }
}
