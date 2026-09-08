// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title RebasingToken
 * @notice A token whose balances all change together, the way a rebasing token does.
 *
 * @dev Balances are held as shares and reported as shares scaled by an index. A rebase moves the index, so every
 * holder's reported balance moves at once and nobody's transaction caused it. That is the property under test: a
 * pool holding this token gains and loses value without any swap, deposit or withdrawal happening.
 *
 * Deliberately minimal, and for demonstration only. Real rebasing tokens differ in the details (opt-out lists,
 * negative rebase floors, permissioned rebasers) and none of those details change what is being demonstrated.
 */
contract RebasingToken is ERC20 {
    /// @notice Fixed point one, and the index a fresh token starts at.
    uint256 public constant ONE = 1e18;

    /// @notice The current scaling factor from shares to balances.
    uint256 public index = ONE;

    /// @notice Shares held, before scaling.
    mapping(address => uint256) public sharesOf;

    /// @notice Shares in existence, before scaling.
    uint256 public totalShares;

    /// @dev A rebase to zero would erase every balance and cannot be undone.
    error InvalidIndex();

    /// @notice Emitted when the index moves, with the factor applied in basis points.
    event Rebased(uint256 newIndex, uint256 factorBps);

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    /// @notice Mints `amount` of balance to `to` at the current index.
    function mint(address to, uint256 amount) external {
        uint256 shares = (amount * ONE) / index;
        sharesOf[to] += shares;
        totalShares += shares;
        emit Transfer(address(0), to, amount);
    }

    /**
     * @notice Scales every balance by `factorBps` basis points.
     * @dev Ten thousand leaves balances unchanged, twenty thousand doubles them, five thousand halves them.
     */
    function rebase(uint256 factorBps) external {
        uint256 next = (index * factorBps) / 10_000;
        if (next == 0) revert InvalidIndex();
        index = next;
        emit Rebased(next, factorBps);
    }

    /// @inheritdoc ERC20
    function totalSupply() public view override returns (uint256) {
        return (totalShares * index) / ONE;
    }

    /// @inheritdoc ERC20
    function balanceOf(address account) public view override returns (uint256) {
        return (sharesOf[account] * index) / ONE;
    }

    /// @dev Moves shares rather than balances, which is what makes a rebase apply to everybody at once.
    function _update(address from, address to, uint256 value) internal override {
        uint256 shares = (value * ONE) / index;
        if (from != address(0)) {
            uint256 held = sharesOf[from];
            require(held >= shares, "balance too low");
            sharesOf[from] = held - shares;
        } else {
            totalShares += shares;
        }
        if (to != address(0)) {
            sharesOf[to] += shares;
        } else {
            totalShares -= shares;
        }
        emit Transfer(from, to, value);
    }
}
