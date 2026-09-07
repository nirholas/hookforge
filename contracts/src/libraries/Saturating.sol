// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/**
 * @title Saturating
 * @notice Counters that stop at their maximum instead of wrapping.
 * @dev For published statistics, overflow is worse than saturation. A wrapped counter silently reports a small number
 * where a huge one belongs, and every ratio derived from it becomes nonsense with no signal that anything happened. A
 * saturated counter stops moving and keeps the last true value, which is wrong in a way a reader can notice and
 * reason about.
 */
library Saturating {
    /// @notice `value + 1`, capped at `type(uint32).max`.
    function inc32(uint32 value) internal pure returns (uint32) {
        return value == type(uint32).max ? value : value + 1;
    }

    /// @notice `value + amount`, capped at `type(uint64).max`.
    function add64(uint64 value, uint256 amount) internal pure returns (uint64) {
        uint256 sum = uint256(value) + amount;
        // Casting to 'uint64' is safe because the branch is only taken when `sum` is below type(uint64).max.
        // forge-lint: disable-next-line(unsafe-typecast)
        return sum >= type(uint64).max ? type(uint64).max : uint64(sum);
    }
}
