// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title FeeOnTransferToken
 * @notice A token that takes a cut of every transfer, so the recipient receives less than the sender sent.
 *
 * @dev The property under test is the one that breaks naive accounting everywhere: `transfer(to, 100)` succeeds and
 * `to` is credited with less than a hundred. Anything that assumes the two numbers are equal, which is most things,
 * is wrong by exactly the fee.
 *
 * The fee is settable so a test can change it mid-run, because a hook that reads a configured constant would pass a
 * fixed-fee test and fail against the real tokens, many of which vary their fee by transfer, by holder or by time.
 * For demonstration only.
 */
contract FeeOnTransferToken is ERC20 {
    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice The cut taken from every transfer, in basis points.
    uint256 public feeBps;

    /// @dev A fee of the whole transfer would leave nothing to receive.
    error InvalidFee();

    constructor(string memory name_, string memory symbol_, uint256 _feeBps) ERC20(name_, symbol_) {
        if (_feeBps >= BPS) revert InvalidFee();
        feeBps = _feeBps;
    }

    /// @notice Mints `amount` to `to`, with no fee, so a test can fund an account exactly.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Changes the transfer fee.
    function setFee(uint256 _feeBps) external {
        if (_feeBps >= BPS) revert InvalidFee();
        feeBps = _feeBps;
    }

    /// @dev Burns the fee rather than routing it anywhere, since where it goes is beside the point being made.
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = (value * feeBps) / BPS;
        super._update(from, to, value - fee);
        if (fee > 0) super._update(from, address(0), fee);
    }
}
