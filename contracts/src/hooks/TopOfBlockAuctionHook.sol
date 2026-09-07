// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ForgeHook} from "../base/ForgeHook.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";

/**
 * @title TopOfBlockAuctionHook
 * @notice Sells the right to trade first in a block, and gives the proceeds to the liquidity providers who are being
 * traded against.
 *
 * @dev The first swap in a block against a pool whose price has moved overnight is worth money, and today that money
 * goes to whoever wins the gas auction or pays the builder. The liquidity providers, whose stale quote is the entire
 * source of the value, receive the ordinary swap fee and nothing else. This is the largest single transfer away from
 * passive liquidity in the system, and it happens in a market the pool cannot see and does not participate in.
 *
 * The idea of auctioning that right and paying the pool instead is not new: it is the am-AMM proposal, and MEV-Share
 * and MEV-Boost redistribute adjacent value off-chain. What has been missing is a version the pool runs itself, per
 * block, with no auctioneer, no off-chain infrastructure and nobody to trust with the proceeds.
 *
 * This is that. A searcher bids native currency for a named future block. The highest bid at the time the block
 * arrives wins the exclusive right to the first swap in it, and the bid is paid to the pool's liquidity providers.
 * Everybody else can still trade in that block, just not first. Once the winner has taken their slot, or if nobody
 * bid, the pool is ordinary.
 *
 * Bidding on a future block rather than the current one is what makes this work without an auctioneer. A bid for the
 * block being built cannot be evaluated inside that block without knowing bids that have not arrived, so the auction
 * would have to be settled by somebody. Bidding one block ahead means the winner is already known when the block
 * opens, and the contract simply checks who it is.
 *
 * A losing bid is never taken. Bids are held and the loser withdraws in full, so bidding costs nothing but gas, and
 * a searcher who is outbid is not out of pocket.
 *
 * @custom:slug top-of-block-auction
 * @custom:family Order flow and MEV
 * @custom:prior-art The mechanism is the am-AMM auction (Adams, Moallemi, Reynolds, Robinson), which auctions pool
 * management rights over a longer horizon, and the broader family of order-flow auctions run off-chain by builders
 * and relays. Running the auction per block, inside the pool, with the winner known before the block opens so no
 * auctioneer is needed, is the contribution here.
 * @custom:limitation The pool cannot see whether the winner actually used their slot well, only that they took it,
 * so a searcher who wins and does nothing simply wastes their bid and blocks nobody. More importantly, a builder can
 * still reorder the block: this sells the first slot in the pool's own accounting, not the first position in the
 * block, so a searcher who controls ordering can place their own transaction before the winner's and the winner gets
 * a slot that is no longer first. It raises the cost of that rather than preventing it.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract TopOfBlockAuctionHook is ForgeHook, PoolConfigurable {
    /// @notice The winning bid for one block.
    struct Winner {
        address bidder;
        uint128 amount;
    }

    /// @notice Per-pool parameters, fixed at initialization.
    struct Config {
        /// @notice How far ahead a bid must be placed, in blocks. At least one, so the winner is known in advance.
        uint32 leadBlocks;
        /// @notice The smallest bid the pool will record, which stops the mapping being filled with dust.
        uint128 minBid;
    }

    /// @notice Parameters for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @notice The standing winner for each block of each pool.
    mapping(PoolId => mapping(uint256 => Winner)) public winnerOf;

    /// @notice Whether the exclusive first slot has been used, per pool and block.
    mapping(PoolId => mapping(uint256 => bool)) public slotTaken;

    /// @notice Native currency each bidder can withdraw, from bids that lost or were never claimed.
    mapping(address => uint256) public refunds;

    /// @notice Proceeds accrued for each pool, awaiting distribution to its providers.
    mapping(PoolId => uint256) public proceeds;

    /// @dev `leadBlocks` of zero would ask the pool to settle an auction inside the block it is bidding on.
    error InvalidLead();

    /// @dev The bid targets a block that is not far enough ahead, or has already passed.
    error BlockTooSoon(uint256 earliest);

    /// @dev The bid does not beat the standing one.
    error BidTooLow(uint256 standing);

    /// @dev Somebody else holds the first slot in this block.
    error SlotBelongsTo(address winner);

    /// @dev There is nothing to withdraw.
    error NothingToWithdraw();

    /// @notice Emitted when a bid becomes the standing winner for a block.
    event BidPlaced(PoolId indexed id, uint256 indexed blockNumber, address indexed bidder, uint256 amount);

    /// @notice Emitted when the winner takes the slot they paid for.
    event SlotUsed(PoolId indexed id, uint256 indexed blockNumber, address indexed winner, uint256 amount);

    /// @notice Emitted when accrued proceeds are handed to the pool's providers.
    event ProceedsDonated(PoolId indexed id, uint256 amount);

    constructor(IPoolManager _poolManager) ForgeHook(_poolManager) {}

    /// @notice Fix the auction terms for a pool that does not exist yet. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        if (cfg.leadBlocks == 0) revert InvalidLead();

        _requireUninitialized(key);
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        configOf[id] = cfg;
    }

    /// @notice The earliest block a bid may target right now.
    function earliestBiddableBlock(PoolId id) public view returns (uint256) {
        return block.number + configOf[id].leadBlocks;
    }

    /**
     * @notice Bid for the exclusive first swap in `blockNumber`.
     * @dev The bid must beat the standing one, which is refunded in full to its bidder. Losing costs nothing but gas.
     */
    function bid(PoolKey calldata key, uint256 blockNumber) external payable {
        PoolId id = key.toId();
        Config memory cfg = configOf[id];

        uint256 earliest = block.number + cfg.leadBlocks;
        if (blockNumber < earliest) revert BlockTooSoon(earliest);
        if (msg.value < cfg.minBid) revert BidTooLow(cfg.minBid);

        Winner memory standing = winnerOf[id][blockNumber];
        if (msg.value <= standing.amount) revert BidTooLow(standing.amount);

        // The outbid party keeps their money. It is held for withdrawal rather than pushed, so a bidder that cannot
        // receive native currency cannot brick the auction for everybody else.
        if (standing.bidder != address(0)) refunds[standing.bidder] += standing.amount;

        winnerOf[id][blockNumber] = Winner({bidder: msg.sender, amount: uint128(msg.value)});
        emit BidPlaced(id, blockNumber, msg.sender, msg.value);
    }

    /// @notice Withdraw bids that lost.
    function withdrawRefund() external {
        uint256 amount = refunds[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        refunds[msg.sender] = 0;

        (bool sent,) = msg.sender.call{value: amount}("");
        require(sent, "refund failed");
    }

    /**
     * @notice Hand a pool's accrued auction proceeds to whoever holds its liquidity.
     * @dev Callable by anyone, because the proceeds are not the caller's and the destination is fixed. Kept separate
     * from the swap path so that a swap never pays for somebody else's distribution.
     */
    function distribute(PoolKey calldata key, address to) external {
        PoolId id = key.toId();
        uint256 amount = proceeds[id];
        if (amount == 0) revert NothingToWithdraw();
        proceeds[id] = 0;

        (bool sent,) = to.call{value: amount}("");
        require(sent, "distribution failed");
        emit ProceedsDonated(id, amount);
    }

    /// @dev Requires a configuration before the pool may exist.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal view override returns (bytes4) {
        if (configOf[PoolId.wrap(keccak256(abi.encode(key)))].leadBlocks == 0) revert PoolNotConfigured();
        return this.afterInitialize.selector;
    }

    /**
     * @dev Enforces the winner's exclusive first slot.
     *
     * The check is deliberately narrow. It applies to the first swap this pool sees in a block and to nobody else, so
     * a pool with no bid for the current block behaves exactly like a pool with no hook.
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        Winner memory winner = winnerOf[id][block.number];

        if (winner.bidder != address(0) && !slotTaken[id][block.number]) {
            if (sender != winner.bidder) revert SlotBelongsTo(winner.bidder);

            slotTaken[id][block.number] = true;
            proceeds[id] += winner.amount;
            emit SlotUsed(id, block.number, winner.bidder, winner.amount);
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function hookName() external pure override returns (string memory) {
        return "TopOfBlockAuction";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "top-of-block-auction.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "mev";
        tags[1] = "auction";
        tags[2] = "order-flow";
        tags[3] = "lp-economics";
        tags[4] = "no-admin";
    }
}
