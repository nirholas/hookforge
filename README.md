# HookForge

**50 production Uniswap v4 hooks that do not exist yet.**

Uniswap v4 turned the AMM into a platform, and most of what has been built on it so far is a re-implementation of
something that already worked: limit orders, TWAMM, KYC gates, another dynamic fee. HookForge is a catalogue of the
mechanisms that are *missing*. Every hook here is checked against the ~140 published hooks and hackathon submissions
before it is written, each one ships with its prior art stated in the source, and each one is a complete contract with
tests, a deployment script, a TypeScript client and a page in the docs.

Nothing here is a sketch. There are no mocks, no `TODO`s and no stubs. If a hook is listed as shipped, it compiles,
its tests pass against a real `PoolManager`, and it can be deployed with one command.

- **Chains:** Base, Arbitrum One, Unichain, Robinhood Chain, and any EVM chain with a v4 `PoolManager`.
- **Built on:** [Uniswap v4-core](https://github.com/Uniswap/v4-core) and OpenZeppelin's audited
  [uniswap-hooks](https://github.com/OpenZeppelin/uniswap-hooks) base contracts.
- **Licence:** Apache-2.0.

## Why the hooks are discoverable

A hook is an address in a `PoolKey`. Nothing about that address tells an indexer, a wallet, a router or an agent what
the pool actually does, which is why hook discovery today is a curated list maintained by hand.

Every HookForge hook answers for itself. It implements `IHookMetadata`, four view functions that return a name, a
version, a tag list and a URI pointing at a machine-readable manifest:

```solidity
interface IHookMetadata {
    function hookName() external view returns (string memory);
    function hookVersion() external view returns (string memory);
    function specURI() external view returns (string memory);
    function hookTags() external view returns (string[] memory);
}
```

Ask any HookForge address what it is and it will tell you, on-chain, in one `eth_call`, with no registry in the loop.
The hooks are also submitted to [Uniswap's hooklist](https://github.com/Uniswap/hooklist) and published as an MCP
server so that coding agents can read the catalogue directly.

## The catalogue

Status is honest: **shipped** means the contract, its tests and its documentation are all in this repository.

### Order flow and MEV

| Hook | What it does | Status |
| --- | --- | --- |
| [`ArbTaxDecay`](contracts/src/hooks/ArbTaxDecayHook.sol) | Prices staleness: the longer a pool sits untraded, the more the next swap pays, on a saturating curve. Recaptures loss-versus-rebalancing with no oracle. | shipped |
| [`PriorityFeeTax`](contracts/src/hooks/PriorityFeeTaxHook.sol) | Charges a surcharge proportional to the swap's own priority fee, on the theory that toxic flow bids for position and benign flow does not. | shipped |
| `BlockBatchClearing` | Queues every swap in a block and clears them at one uniform price, so ordering inside the block stops being worth anything. | building |
| [`TopOfBlockAuction`](contracts/src/hooks/TopOfBlockAuctionHook.sol) | Sells the right to trade first in a block and pays the proceeds to the providers whose stale quote created the value. | shipped |
| [`FlowClassifier`](contracts/src/hooks/FlowClassifierHook.sol) | Publishes on-chain how much of a pool's flow arrives first in the block and how far it moves the price, as a public good other hooks can read. Changes nothing about the pool it measures. | shipped |
| [`ImpactSplit`](contracts/src/hooks/ImpactSplitHook.sol) | Charges each swap for its price impact, holds the charge, then splits it: the share of the move that survived a settlement window goes to providers, the share that decayed goes back to the trader. Permanent versus temporary impact, decided by the price rather than guessed at. | shipped |
| [`BlockReversal`](contracts/src/hooks/BlockReversalHook.sol) | Charges the swap that unwinds the current block's own price move, which is the only leg of a sandwich identifiable without knowing who is trading. Replaces the address-based `SandwichBond` sketch, which a second EOA defeats. | shipped |

### Curves

| Hook | What it does | Status |
| --- | --- | --- |
| [`YieldSpace`](contracts/src/hooks/YieldSpaceHook.sol) | A fixed-rate curve with a maturity that converges to par on its own, so a rates market is an ordinary v4 pool. | shipped |
| [`LMSR`](contracts/src/hooks/LMSRHook.sol) | Hanson's bounded-loss scoring rule as a two-sided pool curve, with the bound published as an on-chain view a provider reads before depositing. A trade a thousand times the pool's size settles and leaves it standing. | shipped |
| [`PowerPerp`](contracts/src/hooks/PowerPerpHook.sol) | A weighted geometric-mean curve, so a provider chooses how much of the price move they want instead of always getting the square root of it. | shipped |
| [`RatchetFloor`](contracts/src/hooks/RatchetFloorHook.sol) | A protocol-owned bid that can only move up, giving a token a floor price that is enforced by the curve. | shipped |
| [`GridLadder`](contracts/src/hooks/GridLadderHook.sol) | Quotes an independent bid and ask, so a pool can hold a market maker's position rather than a fee schedule. | shipped |
| [`DutchClearingLaunch`](contracts/src/hooks/DutchClearingLaunchHook.sol) | A descending-price launch enforced as a floor on what the pool will sell at, so the opening price is discovered rather than declared. | shipped |
| [`StepCurve`](contracts/src/hooks/StepCurveHook.sol) | Prices in discrete increments instead of continuously, so a quote is firm below the increment and there is no infinitesimal arbitrage to take. | shipped |

### Token mechanics

| Hook | What it does | Status |
| --- | --- | --- |
| [`RebaseAbsorb`](contracts/src/hooks/RebaseAbsorbHook.sol) | Holds its reserves as real tokens at its own address rather than as claims in the singleton, so a rebase, dividend or airdrop of the pool's tokens is attributable to one pool and already belongs to its share holders. Covers `DividendPassthrough` too. | shipped |
| `FeeOnTransfer` | Partly covered by [`RebaseAbsorb`](contracts/src/hooks/RebaseAbsorbHook.sol), which settles a taxed payout exactly. A taxed *input* cannot be balanced by a hook at all: whatever the swapper sends is taxed before the manager counts it, so only a router that over-sends can cover the shortfall. Stated rather than faked. | shipped |
| `YieldDiscount` | Parks idle reserves in an ERC-4626 vault and pays the yield out as fee discounts to swappers. | building |
| `DividendPassthrough` | Folded into [`RebaseAbsorb`](contracts/src/hooks/RebaseAbsorbHook.sol): from the pool's point of view a dividend paid to holders and a rebase are the same event, and the same reserve-as-balance mechanism absorbs both. | shipped |
| `WrappedNativeYield` | On chains with native yield, donates the pool's accrued yield to in-range liquidity. | building |

### Risk

| Hook | What it does | Status |
| --- | --- | --- |
| [`CircuitBreaker`](contracts/src/hooks/CircuitBreakerHook.sol) | Halts swaps after a move larger than a threshold and resumes automatically after a cooldown. Withdrawals stay open. | shipped |
| [`OracleBand`](contracts/src/hooks/OracleBandHook.sol) | Requires a swap to clear within a band around a signed reference price, so a thin pool cannot be walked away from reality. | shipped |
| [`DepegShield`](contracts/src/hooks/DepegShieldHook.sol) | For pegged pairs: fees rise superlinearly with distance from the peg and fall for swaps that restore it. | shipped |
| [`ILInsurance`](contracts/src/hooks/ILInsuranceHook.sol) | Pays providers back for divergence loss out of a fund the pool's own trading fills, capped by what the fund actually holds. | shipped |
| [`DrawdownCap`](contracts/src/hooks/DrawdownCapHook.sol) | Caps how much price impact one address may cause per epoch. | shipped |
| [`LiquidityFloor`](contracts/src/hooks/LiquidityFloorHook.sol) | Holds each position to a fraction of its own additions until an unlock date, so commitments are fractional and race-free. | shipped |

### Liquidity provider economics

| Hook | What it does | Status |
| --- | --- | --- |
| [`TickHarberger`](contracts/src/hooks/TickHarbergerHook.sol) | Leases the right to set the fee one tick range at a time under a continuous self-assessed tax, so price levels are priced separately and the rent goes to the providers being priced. | shipped |
| [`TenureWeightedFees`](contracts/src/hooks/TenureWeightedFeesHook.sol) | Skims a slice of each swap into a pot shared by tenure, so staying is paid without arriving being taxed. | shipped |
| `RangeRent` | Charges and pays rent for range occupancy based on how much of the range was actually used. | building |
| `AutoCompoundDonate` | Donates accrued fees straight back to in-range liquidity, compounding without touching positions. | building |
| [`RetroRebate`](contracts/src/hooks/RetroRebateHook.sol) | Pays volume rebates from closed on-chain epochs, so there is no Merkle root, no off-chain script and nobody who can decline to publish it. | shipped |
| [`FungibleRange`](contracts/src/hooks/FungibleRangeHook.sol) | A concentrated position with fungible shares whose band widens every time it is forced to move and narrows again while quiet, so attacking the rebalance damps itself. No keeper, no manager. | shipped |

### Agent-native

| Hook | What it does | Status |
| --- | --- | --- |
| [`X402Gate`](contracts/src/hooks/X402GateHook.sol) | Meters pool access with x402 payment receipts, so an autonomous agent can pay per swap for a better fee tier. The 402 challenge is an `eth_call` and settlement is atomic with the swap. | shipped |
| [`ReputationFee`](contracts/src/hooks/ReputationFeeHook.sol) | Prices a counterparty by its on-chain reputation, resolved through a router it registered, so no signature or hookData is needed. | shipped |
| [`AgentBudget`](contracts/src/hooks/AgentBudgetHook.sol) | Enforces a signed per-epoch spend budget in the pool itself, so a delegated agent key is bounded by the venue rather than by its own code. | shipped |
| `IntentSettle` | Settles signed ERC-7683 intents against pool liquidity, with solvers competing on the fill. | building |
| `HookMeter` | Instruments another hook: gas, revert rate and fee take, published on-chain for anyone to audit. | building |
| `HookStack` | Runs an ordered stack of sub-hooks on one pool, each with its own gas budget. | building |

### Time

| Hook | What it does | Status |
| --- | --- | --- |
| [`ExpirySettle`](contracts/src/hooks/ExpirySettleHook.sol) | Gives a pool a maturity, and ramps the fee quadratically into it, so the settlement price is dearest to move exactly when moving it would pay most. | shipped |
| [`VestedBuy`](contracts/src/hooks/VestedBuyHook.sol) | Vests the purchase at the pool rather than the token, so a launch gets holders while the token stays a plain ERC-20. | shipped |
| [`EpochRebalance`](contracts/src/hooks/EpochRebalanceHook.sol) | An index whose entire weight schedule is fixed before anybody deposits, gliding continuously so no single block is worth racing to. | shipped |
| [`StreamDCA`](contracts/src/hooks/StreamDCAHook.sol) | Value averaging rather than dollar-cost averaging: the per-period buy is sized by how far the position is from its target, so a cheaper price buys more. Settled in batches inside unrelated swaps. | shipped |
| [`TradingCalendar`](contracts/src/hooks/TradingCalendarHook.sol) | Opens and closes the pool on a schedule, ramping fees at the edges instead of slamming shut. | shipped |

### Cross-domain and information

| Hook | What it does | Status |
| --- | --- | --- |
| `SharedLiquidity` | Mirrors one pool across chains and settles the net position, so liquidity is not fragmented per chain. | building |
| `L1Anchor` | Anchors an L2 pool to a proven L1 price. | building |
| [`VarianceSwap`](contracts/src/hooks/VarianceSwapHook.sol) | Measures the pool's realised variance from its own ticks and lets either side be taken: deposit collateral to be short volatility and collect premiums, or buy a fully collateralised note to be long it. The exposure a provider already has, and its hedge, in one contract. | shipped |
| [`MarkoutFee`](contracts/src/hooks/MarkoutFeeHook.sol) | Grades each swap after the fact by whether the price kept moving its way, and prices the next one from the running average. A fee that measures adverse selection instead of guessing at it. | shipped |
| [`AntiSnipeRamp`](contracts/src/hooks/AntiSnipeRampHook.sol) | Starts a launch at a punitive fee that decays to normal, paying the difference to liquidity providers rather than the deployer. | shipped |
| [`CommitRevealDark`](contracts/src/hooks/CommitRevealDarkHook.sol) | Accepts only swaps that were committed to in an earlier block, so seeing an order stops being useful and nobody has to be trusted to hide it. | shipped |
| `LotteryFees` | Sends a slice of fees to a no-loss lottery among the pool's liquidity providers. | building |
| [`ReserveStable`](contracts/src/hooks/ReserveStableHook.sol) | Pays a bounded rebate to whoever restores a pegged pool's balance, funded solely by the surcharge it collected while losing it, and provably unable to pay out more than it took in. | shipped |

## Repository layout

```
contracts/          Foundry project: hooks, shared bases, libraries, tests, deploy scripts
  src/hooks/        One file per hook
  src/base/         ForgeHook, ForgeFeeHook, ForgeMetadata, PoolConfigurable
  src/libraries/    Shared math
  test/             One suite per hook, plus fuzz and invariant tests
packages/sdk/       TypeScript client: addresses, ABIs, quote helpers
packages/registry/  Machine-readable hook manifests and the hooklist submissions
packages/mcp/       MCP server so coding agents can query the catalogue
apps/web/           hookforge.pages.dev: 3D catalogue and documentation
docs/               Long-form documentation, one page per hook
```

## Build and test

```bash
git clone --recurse-submodules https://github.com/nirholas/hookforge
cd hookforge/contracts
forge build
forge test
```

Foundry 1.7 or newer, Solidity 0.8.26, EVM version `cancun` (v4 requires transient storage).

## Deployed addresses

Deployment addresses are published in [`packages/registry`](packages/registry) and on
[hookforge.dev](https://hookforge.pages.dev) as each hook ships.

## Contributing

Hook ideas are welcome, especially ones this catalogue has missed. Open an issue describing the mechanism and what
existing hook it is *not*. The prior-art check is the hard part, and it is the part that makes this repository worth
reading.
