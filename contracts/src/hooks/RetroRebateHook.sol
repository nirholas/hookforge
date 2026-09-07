// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {BaseHookFee} from "uniswap-hooks/fee/BaseHookFee.sol";

import {ForgeMetadata} from "../base/ForgeMetadata.sol";
import {ForgePayout} from "../base/ForgePayout.sol";

/**
 * @title RetroRebateHook
 * @notice A volume rebate the pool pays out of its own flow, settled on-chain at the end of each epoch, with no
 * Merkle root, no off-chain calculation and nobody who can decline to publish it.
 *
 * @dev Volume rebates are how every venue rewards its best flow, and on-chain they are almost always a lie about
 * where the computation happens. A team totals volume off-chain, posts a Merkle root, and traders claim against it.
 * The rebate is real; the decentralisation is not. Whoever runs the script chooses who is in the tree, can publish
 * late, can publish never, and is the only party who can tell you whether the number is right.
 *
 * The reason it is done that way is that per-trader accounting looks expensive, and in a continuous scheme it is:
 * paying a share of a pot that is still growing means either an accumulator per trader or an unbounded loop.
 *
 * Epochs make it cheap. The hook skims `skimBps` of every swap into that epoch's pot and records the volume each
 * account traded in it, which is two storage writes. Once an epoch has closed, both numbers are final, so a claim is
 * one multiplication and a transfer:
 *
 *   payout = pot(epoch) * volume(epoch, account) / totalVolume(epoch)
 *
 * There is nothing to publish, nothing to compute off-chain, and nothing anybody can withhold. A trader who never
 * claims simply leaves their share, and because a closed epoch's pot is fixed, that costs nobody else anything.
 *
 * Volume is attributed to whatever address the swap names in `hookData`, and this deliberately needs no signature.
 * Naming somebody else credits them with volume you paid for, so the only thing a forged attribution achieves is
 * giving away your own rebate. A swap that names nobody credits the router it came through, which lets a router run
 * the rebate for its users and split it however it likes.
 *
 * @custom:slug retro-rebate
 * @custom:family Liquidity provider economics
 * @custom:prior-art Volume rebates, referral fees and loyalty discounts all exist as hooks, and all of them either discount at the point of trade (which cannot depend on a total that is not known yet) or settle against an off-chain Merkle root. Doing the accounting on-chain in closed epochs, so the rebate is a division anybody can verify and nobody can withhold, is the contribution here.
 * @custom:limitation The rebate arrives after the epoch ends, so it is worth less than the same value taken off the trade, and a trader who wants a discount now is better served by a hook that discounts now. Epoch length is a real tradeoff rather than a parameter to shrug at: short epochs pay out sooner and let a single large trade dominate a small pot, long ones smooth that out and make the rebate feel remote.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract RetroRebateHook is BaseHookFee, ForgeMetadata, ForgePayout {
    /// @notice The slice of each swap that funds the rebate pot, in hundredths of a bip.
    uint24 public immutable skimBps;

    /// @notice How long an epoch runs, in seconds.
    uint32 public immutable epochLength;

    /// @notice The pool this hook serves, bound at its first initialization.
    PoolId public boundPool;

    /// @notice Volume each account traded in each epoch, measured in the unspecified currency of its swaps.
    mapping(uint256 => mapping(address => uint256)) public volumeOf;

    /// @notice Total volume traded in each epoch.
    mapping(uint256 => uint256) public totalVolume;

    /// @notice The pot accumulated in each epoch, per currency.
    mapping(uint256 => uint256) public pot0;
    mapping(uint256 => uint256) public pot1;

    /// @notice Whether an account has already claimed its share of an epoch.
    mapping(uint256 => mapping(address => bool)) public claimed;

    /// @dev The skim must leave the swap worth doing.
    error SkimTooLarge();

    /// @dev An epoch length of zero would make every swap its own epoch and every pot a rounding error.
    error InvalidEpoch();

    /// @dev This hook serves one pool, bound at its first initialization.
    error WrongPool();

    /// @dev The epoch is still running, so its pot and its total are not final.
    error EpochNotClosed(uint256 epoch);

    /// @dev This account has already taken its share of that epoch.
    error AlreadyClaimed(uint256 epoch);

    /// @dev The account traded nothing in that epoch.
    error NothingToClaim(uint256 epoch);

    /// @notice Emitted for every swap, recording who it was attributed to.
    event VolumeRecorded(uint256 indexed epoch, address indexed account, uint256 volume);

    /// @notice Emitted when an account takes its rebate.
    event RebateClaimed(uint256 indexed epoch, address indexed account, uint256 amount0, uint256 amount1);

    /// @dev The pool key this hook was bound to, kept so claims know which currencies to pay in.
    PoolKey private _boundKey;

    constructor(IPoolManager _poolManager, uint24 _skimBps, uint32 _epochLength) BaseHook(_poolManager) {
        if (_skimBps > 100_000) revert SkimTooLarge();
        if (_epochLength == 0) revert InvalidEpoch();
        skimBps = _skimBps;
        epochLength = _epochLength;
    }

    /// @notice The epoch a timestamp falls in. Epochs are aligned to absolute time, so every pool agrees on them.
    function epochAt(uint256 timestamp) public view returns (uint256) {
        return timestamp / epochLength;
    }

    /// @notice The epoch currently running.
    function currentEpoch() public view returns (uint256) {
        // Epochs are hours or days long; the seconds a proposer can shift cannot move a boundary meaningfully.
        // forge-lint: disable-next-line(block-timestamp)
        return epochAt(block.timestamp);
    }

    /**
     * @notice What `account` could claim for `epoch`, once it has closed.
     * @dev Returns zero for the running epoch rather than a provisional figure, because a provisional rebate is a
     * number people will act on and it is not one.
     */
    function claimable(uint256 epoch, address account) public view returns (uint256 amount0, uint256 amount1) {
        if (epoch >= currentEpoch()) return (0, 0);
        if (claimed[epoch][account]) return (0, 0);

        uint256 total = totalVolume[epoch];
        if (total == 0) return (0, 0);

        uint256 share = volumeOf[epoch][account];
        amount0 = (pot0[epoch] * share) / total;
        amount1 = (pot1[epoch] * share) / total;
    }

    /// @notice Take the caller's rebate for a closed epoch.
    function claim(uint256 epoch, address to) external returns (uint256 amount0, uint256 amount1) {
        if (epoch >= currentEpoch()) revert EpochNotClosed(epoch);
        if (claimed[epoch][msg.sender]) revert AlreadyClaimed(epoch);
        if (volumeOf[epoch][msg.sender] == 0) revert NothingToClaim(epoch);

        (amount0, amount1) = claimable(epoch, msg.sender);
        claimed[epoch][msg.sender] = true;

        PoolKey memory key = _boundKey;
        // Paid as real tokens, not as claims: a rebate the recipient has to know to redeem is not a rebate.
        _payout(key.currency0, key.currency1, to, amount0, amount1);

        emit RebateClaimed(epoch, msg.sender, amount0, amount1);
    }

    /// @dev Binds the hook to one pool and records its key.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        if (PoolId.unwrap(boundPool) != bytes32(0)) revert WrongPool();
        boundPool = key.toId();
        _boundKey = key;
        return this.afterInitialize.selector;
    }

    /// @dev The slice of each swap that funds the pot.
    function _getHookFee(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        view
        override
        returns (uint24)
    {
        return skimBps;
    }

    /// @dev Records the swap's volume against whoever it names, and books the skim into this epoch's pot.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        (uint256 before0, uint256 before1) = _held(key);
        (bytes4 selector, int128 hookDelta) = super._afterSwap(sender, key, params, delta, hookData);
        _record(key, sender, hookData, before0, before1);
        return (selector, hookDelta);
    }

    /// @dev What the hook currently holds of each of the pool's currencies, as ERC-6909 claims.
    function _held(PoolKey calldata key) private view returns (uint256 held0, uint256 held1) {
        held0 = poolManager.balanceOf(address(this), key.currency0.toId());
        held1 = poolManager.balanceOf(address(this), key.currency1.toId());
    }

    /**
     * @dev Books the skim and credits the volume.
     *
     * Volume is measured by what the skim was taken from, which is the swap's unspecified currency. That is a
     * consistent unit within a currency but not across the pair, so a pool whose two sides differ wildly in value
     * will weight one side's flow more heavily. Stated rather than corrected, because correcting it would need a
     * price, and needing a price is how a rebate scheme acquires an oracle.
     */
    function _record(PoolKey calldata key, address sender, bytes calldata hookData, uint256 before0, uint256 before1)
        private
    {
        (uint256 after0, uint256 after1) = _held(key);
        uint256 gained0 = after0 - before0;
        uint256 gained1 = after1 - before1;
        uint256 volume = gained0 + gained1;
        if (volume == 0) return;

        // A swap may name its beneficiary. No signature is needed: naming somebody else gives away your own rebate,
        // which is the only thing a forged attribution can achieve.
        address account = hookData.length == 32 ? abi.decode(hookData, (address)) : sender;

        uint256 epoch = currentEpoch();
        pot0[epoch] += gained0;
        pot1[epoch] += gained1;
        volumeOf[epoch][account] += volume;
        totalVolume[epoch] += volume;

        emit VolumeRecorded(epoch, account, volume);
    }

    /**
     * @dev The base contract's sweep for accumulated fees, unused here.
     *
     * Every skim is booked to an epoch pot the moment it lands and belongs to the traders of that epoch. There is no
     * unattributed balance to sweep, and providing a route to move one would be a route to move somebody's rebate.
     */
    function handleHookFees(Currency[] memory) public pure override {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
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

    /// @inheritdoc ForgePayout
    function _payoutManager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function hookName() external pure override returns (string memory) {
        return "RetroRebate";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "retro-rebate.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "rebate";
        tags[1] = "volume";
        tags[2] = "epochs";
        tags[3] = "no-merkle";
        tags[4] = "no-admin";
    }
}
