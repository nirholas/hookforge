// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {BaseHookFee} from "uniswap-hooks/fee/BaseHookFee.sol";

import {ForgeMetadata} from "../base/ForgeMetadata.sol";
import {ForgePayout} from "../base/ForgePayout.sol";

/**
 * @title ILInsuranceHook
 * @notice Pays liquidity providers back for divergence loss, out of a fund the pool's own trading fills.
 *
 * @dev Impermanent loss is the reason most people who try providing liquidity once do not do it twice. It is also
 * badly named: there is nothing impermanent about it once you withdraw, and the number is not small. A provider who
 * deposits into a pair that then moves has less than they would have had holding, and the fees they earned may or
 * may not have covered it. Nobody tells them which until they leave.
 *
 * The existing answers all come from outside the pool. Bancor underwrote it from a treasury and stopped when the
 * treasury could not take it. Options-based cover needs an options market for the pair. Both are somebody else's
 * balance sheet promising to make a provider whole.
 *
 * This makes the pool underwrite itself. A slice of every swap goes into a fund, and when a provider withdraws, the
 * hook compares what their position is worth against what the same deposit would have been worth held, and pays the
 * difference from the fund up to a cap. Traders pay for the cover through a slightly worse fee, which is the correct
 * party: the cover is what keeps liquidity in the pool they are trading against.
 *
 * The comparison is measured rather than modelled. At deposit the hook records what actually went in; at withdrawal
 * it records what actually came out and values both at the current price. There is no closed-form IL formula here,
 * because the formula assumes a constant-product position held across a single price move, and a v4 position is a
 * range that may have been crossed repeatedly. What went in and what came out are facts, and the difference between
 * them at one price is the loss.
 *
 * Three bounds keep this solvent, and none of them is a promise. A claim never exceeds `coverageBps` of the loss.
 * A claim never exceeds what the fund holds, so the fund cannot go negative and there is no lender of last resort. And
 * cover vests: a position withdrawn before `fullCoverAfter` is covered pro rata to how long it stayed, because
 * insuring a position that arrives, watches one candle and leaves is not insurance, it is a free option on the fund.
 *
 * @custom:slug il-insurance
 * @custom:family Risk
 * @custom:prior-art Bancor v2.1 and v3 underwrote impermanent loss from protocol reserves and suspended it when they could not. Thorchain does the same with a vesting schedule this borrows from. Options-based cover exists where an options market for the pair does. Funding the cover from the pool's own trading flow, inside the pool, with a fund that can only pay what it holds, is the contribution here.
 * @custom:limitation The fund is finite and claims are paid first-come. A pool that suffers a large correlated move after a quiet period will pay early withdrawers in full and later ones partially, which is the honest behaviour of a fund rather than a defect, but it is not the guarantee the word insurance implies. Cover is also valued in currency1 terms at the moment of withdrawal, so a provider withdrawing into a spike is measured against that spike.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract ILInsuranceHook is BaseHookFee, ForgeMetadata, ForgePayout {
    using StateLibrary for IPoolManager;

    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice What the pool remembers about one position, so a claim can be measured rather than modelled.
    struct Cover {
        /// @notice Currency0 the position has put in, net of what it has taken out.
        uint128 deposited0;
        /// @notice Currency1 the position has put in, net of what it has taken out.
        uint128 deposited1;
        /**
         * @notice Liquidity the position currently holds.
         * @dev Tracked so a full exit can be recognised exactly. Uniswap rounds in the pool's favour on both sides,
         * so what comes out is a wei or two short of what went in, and a position that had fully left still looked
         * like it held dust. That dust kept its vesting clock running, so re-entering would have inherited cover it
         * had not earned. Liquidity is the quantity that actually reaches zero.
         */
        uint128 liquidity;
        /// @notice When the position was opened, which is what cover vests against.
        uint64 openedAt;
    }

    /// @notice The slice of each swap that funds the cover, in hundredths of a bip.
    uint24 public immutable premiumBps;

    /// @notice The share of a measured loss the fund will pay, in basis points.
    uint32 public immutable coverageBps;

    /// @notice How long a position must be held for cover to vest fully, in seconds.
    uint32 public immutable fullCoverAfter;

    /// @notice The pool this hook serves, bound at its first initialization.
    PoolId public boundPool;

    /// @notice Cover state per position.
    mapping(bytes32 => Cover) public coverOf;

    /// @notice What the fund holds, per currency, as ERC-6909 claims.
    uint256 public fund0;
    uint256 public fund1;

    /// @notice Total paid out in claims, so the fund's history is public.
    uint256 public paidOut1;

    /// @dev The premium must leave the swap worth doing.
    error PremiumTooLarge();

    /// @dev Coverage above 100% would pay a provider more than they lost.
    error CoverageTooLarge();

    /// @dev This hook serves one pool, bound at its first initialization.
    error WrongPool();

    /// @notice Emitted when a swap adds to the fund.
    event FundGrew(uint256 amount0, uint256 amount1, uint256 fund0, uint256 fund1);

    /// @notice Emitted when a withdrawal is measured, whether or not it produced a claim.
    event LossMeasured(bytes32 indexed position, uint256 heldValue, uint256 positionValue, uint256 claim);

    /// @dev The pool key this hook was bound to, kept so claims know which currencies to pay in.
    PoolKey private _boundKey;

    constructor(IPoolManager _poolManager, uint24 _premiumBps, uint32 _coverageBps, uint32 _fullCoverAfter)
        BaseHook(_poolManager)
    {
        if (_premiumBps > 100_000) revert PremiumTooLarge();
        if (_coverageBps > BPS) revert CoverageTooLarge();
        premiumBps = _premiumBps;
        coverageBps = _coverageBps;
        fullCoverAfter = _fullCoverAfter;
    }

    /// @notice The v4 position key for a range owned by `owner` with `salt`.
    function positionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
    }

    /**
     * @notice The fraction of cover a position has vested, in basis points.
     * @dev Linear in time held, capped at full. A position that arrives, watches one candle and leaves is covered
     * for almost nothing, which is the point: insuring that is a free option on the fund rather than insurance.
     */
    function vestedBps(bytes32 position) public view returns (uint256) {
        Cover memory cover = coverOf[position];
        if (cover.openedAt == 0 || fullCoverAfter == 0) return BPS;
        // Vesting runs for days; the seconds a proposer can shift cannot meaningfully move it.
        // forge-lint: disable-next-line(block-timestamp)
        uint256 held = block.timestamp - cover.openedAt;
        return held >= fullCoverAfter ? BPS : (held * BPS) / fullCoverAfter;
    }

    /**
     * @notice What a position would be paid if it withdrew everything right now.
     * @dev Valued in currency1 at the pool's current price, which is the same basis the claim itself uses.
     */
    function quoteClaim(bytes32 position, uint256 amount0Out, uint256 amount1Out)
        public
        view
        returns (uint256 claim, uint256 heldValue, uint256 positionValue)
    {
        Cover memory cover = coverOf[position];
        if (cover.deposited0 == 0 && cover.deposited1 == 0) return (0, 0, 0);

        uint256 priceX96 = _priceX96();
        heldValue = FullMath.mulDiv(cover.deposited0, priceX96, 1 << 96) + cover.deposited1;
        positionValue = FullMath.mulDiv(amount0Out, priceX96, 1 << 96) + amount1Out;
        if (positionValue >= heldValue) return (0, heldValue, positionValue);

        uint256 loss = heldValue - positionValue;
        claim = (loss * coverageBps) / BPS;
        claim = (claim * vestedBps(position)) / BPS;
        // The fund pays what it holds and never more. There is no lender of last resort behind this.
        if (claim > fund1) claim = fund1;
    }

    /// @dev The pool's current price of currency0 in currency1, as a Q96 ratio.
    function _priceX96() private view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(boundPool);
        return FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
    }

    /// @dev Binds the hook to one pool and records its key.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        if (PoolId.unwrap(boundPool) != bytes32(0)) revert WrongPool();
        boundPool = key.toId();
        _boundKey = key;
        return this.afterInitialize.selector;
    }

    /// @dev Records what actually went in, which is one half of the comparison a claim is measured against.
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        if (params.liquidityDelta > 0) {
            bytes32 position = positionKey(sender, params.tickLower, params.tickUpper, params.salt);
            Cover storage cover = coverOf[position];
            // forge-lint: disable-next-line(block-timestamp)
            if (cover.liquidity == 0) cover.openedAt = uint64(block.timestamp);

            cover.liquidity += uint128(uint256(params.liquidityDelta));
            // A negative delta is what the provider paid in.
            if (delta.amount0() < 0) cover.deposited0 += uint128(-delta.amount0());
            if (delta.amount1() < 0) cover.deposited1 += uint128(-delta.amount1());
        }
        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @dev Measures the loss against what came out, pays what the fund can, and reduces the recorded deposit.
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        if (params.liquidityDelta < 0) {
            _settleWithdrawal(
                positionKey(sender, params.tickLower, params.tickUpper, params.salt),
                key,
                sender,
                delta,
                uint128(uint256(-params.liquidityDelta))
            );
        }
        return (this.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    /**
     * @dev Measures the loss against what came out, pays what the fund can, and reduces the recorded deposit.
     *
     * Split out of the callback because the callback's own frame carries six parameters and the measurement needs
     * several more locals than fit alongside them.
     */
    function _settleWithdrawal(
        bytes32 position,
        PoolKey calldata key,
        address to,
        BalanceDelta delta,
        uint128 liquidityRemoved
    ) private {
        uint256 out0 = delta.amount0() > 0 ? uint256(uint128(delta.amount0())) : 0;
        uint256 out1 = delta.amount1() > 0 ? uint256(uint128(delta.amount1())) : 0;

        (uint256 claim, uint256 heldValue, uint256 positionValue) = quoteClaim(position, out0, out1);

        Cover storage cover = coverOf[position];
        cover.liquidity = liquidityRemoved >= cover.liquidity ? 0 : cover.liquidity - liquidityRemoved;

        if (cover.liquidity == 0) {
            // A full exit clears the record outright rather than leaving the wei of dust that rounding produces.
            cover.deposited0 = 0;
            cover.deposited1 = 0;
            cover.openedAt = 0;
        } else {
            // Both casts are safe: the comparison in each line only reaches the cast when `out` is below a uint128.
            // forge-lint: disable-next-line(unsafe-typecast)
            cover.deposited0 = out0 >= cover.deposited0 ? 0 : cover.deposited0 - uint128(out0);
            // forge-lint: disable-next-line(unsafe-typecast)
            cover.deposited1 = out1 >= cover.deposited1 ? 0 : cover.deposited1 - uint128(out1);
        }

        emit LossMeasured(position, heldValue, positionValue, claim);

        if (claim > 0) {
            fund1 -= claim;
            paidOut1 += claim;
            _payout(key.currency0, key.currency1, to, 0, claim);
        }
    }

    /// @dev The slice of each swap that funds the cover.
    function _getHookFee(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        view
        override
        returns (uint24)
    {
        return premiumBps;
    }

    /// @dev Books whatever the premium took into the fund.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        (uint256 before0, uint256 before1) = _held(key);
        (bytes4 selector, int128 hookDelta) = super._afterSwap(sender, key, params, delta, hookData);
        _bank(key, before0, before1);
        return (selector, hookDelta);
    }

    /// @dev What the hook holds of each of the pool's currencies, as ERC-6909 claims.
    function _held(PoolKey calldata key) private view returns (uint256 held0, uint256 held1) {
        held0 = poolManager.balanceOf(address(this), key.currency0.toId());
        held1 = poolManager.balanceOf(address(this), key.currency1.toId());
    }

    /// @dev Adds whatever the premium just took to the fund.
    function _bank(PoolKey calldata key, uint256 before0, uint256 before1) private {
        (uint256 after0, uint256 after1) = _held(key);
        uint256 gained0 = after0 - before0;
        uint256 gained1 = after1 - before1;
        if (gained0 == 0 && gained1 == 0) return;
        fund0 += gained0;
        fund1 += gained1;
        emit FundGrew(gained0, gained1, fund0, fund1);
    }

    /**
     * @dev The base contract's sweep, unused. Everything the premium takes belongs to the fund and can only leave it
     * as a claim, so a route to move it would be a route to drain the cover providers are relying on.
     */
    function handleHookFees(Currency[] memory) public pure override {}

    /// @inheritdoc ForgePayout
    function _payoutManager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function hookName() external pure override returns (string memory) {
        return "ILInsurance";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "il-insurance.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "risk";
        tags[1] = "impermanent-loss";
        tags[2] = "lp-economics";
        tags[3] = "insurance";
        tags[4] = "no-admin";
    }
}
