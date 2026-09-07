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
- **Licence:** MIT.

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
| `TopOfBlockAuction` | An on-chain auction for the right to trade first in a block. The winning bid is paid to liquidity providers. | building |
| [`FlowClassifier`](contracts/src/hooks/FlowClassifierHook.sol) | Publishes on-chain how much of a pool's flow arrives first in the block and how far it moves the price, as a public good other hooks can read. Changes nothing about the pool it measures. | shipped |
| `ImpactSplit` | Splits a large swap into tranches across blocks and guarantees the result beats immediate execution or refunds the difference. | building |
| `SandwichBond` | Lets a swapper post a bond that is returned unless a same-block backrun is detected, in which case it compensates them. | building |

### Curves

| Hook | What it does | Status |
| --- | --- | --- |
| `YieldSpace` | A fixed-rate curve with a maturity, converging to par at expiry. Interest-rate markets as a native v4 pool. | building |
| `LMSR` | A logarithmic market scoring rule curve, giving prediction markets bounded loss and always-available liquidity. | building |
| `PowerPerp` | An `x^p` invariant, so an LP position has power-perpetual payoff instead of the usual square-root exposure. | building |
| `RatchetFloor` | A protocol-owned bid that can only move up, giving a token a floor price that is enforced by the curve. | building |
| `GridLadder` | Asymmetric bid and ask ladders in one position, so an LP can quote a spread rather than a symmetric range. | building |
| `DutchClearingLaunch` | A descending-price launch that ends in a single clearing price, refunding everyone who bid above it. | building |
| `StepCurve` | Piecewise-constant prices, for assets that should trade in discrete steps rather than on a continuum. | building |

### Token mechanics

| Hook | What it does | Status |
| --- | --- | --- |
| `RebaseAbsorb` | Makes rebasing tokens safe in v4 by absorbing balance drift into the pool as a donation to liquidity providers. | building |
| `FeeOnTransfer` | Makes fee-on-transfer tokens work by settling on measured balance deltas instead of requested amounts. | building |
| `YieldDiscount` | Parks idle reserves in an ERC-4626 vault and pays the yield out as fee discounts to swappers. | building |
| `DividendPassthrough` | Routes dividends paid to pool-held tokens through to liquidity providers pro rata. | building |
| `WrappedNativeYield` | On chains with native yield, donates the pool's accrued yield to in-range liquidity. | building |

### Risk

| Hook | What it does | Status |
| --- | --- | --- |
| [`CircuitBreaker`](contracts/src/hooks/CircuitBreakerHook.sol) | Halts swaps after a move larger than a threshold and resumes automatically after a cooldown. Withdrawals stay open. | shipped |
| `OracleBand` | Requires a swap to clear within a band around a signed reference price, so a thin pool cannot be walked away from reality. | building |
| [`DepegShield`](contracts/src/hooks/DepegShieldHook.sol) | For pegged pairs: fees rise superlinearly with distance from the peg and fall for swaps that restore it. | shipped |
| `ILInsurance` | Skims a slice of fees into a vault that pays impermanent-loss claims to the providers who funded it. | building |
| `DrawdownCap` | Caps how much price impact one address may cause per epoch. | building |
| [`LiquidityFloor`](contracts/src/hooks/LiquidityFloorHook.sol) | Holds each position to a fraction of its own additions until an unlock date, so commitments are fractional and race-free. | shipped |

### Liquidity provider economics

| Hook | What it does | Status |
| --- | --- | --- |
| `TickHarberger` | Auctions the exclusive right to provide liquidity at the active tick under a Harberger tax, so it is always for sale. | building |
| `TenureWeightedFees` | Weights fee share by continuous time in the pool, so capital that stays is paid more than capital that visits. | building |
| `RangeRent` | Charges and pays rent for range occupancy based on how much of the range was actually used. | building |
| `AutoCompoundDonate` | Donates accrued fees straight back to in-range liquidity, compounding without touching positions. | building |
| `RetroRebate` | Pays volume rebates from on-chain epoch accounting, with no Merkle drop and no off-chain claim. | building |
| `FungibleRange` | Tokenises a range position as an ERC-20 so it can be traded, lent and used as collateral. | building |

### Agent-native

| Hook | What it does | Status |
| --- | --- | --- |
| `X402Gate` | Meters pool access with x402 payment receipts, so an autonomous agent can pay per swap for a better fee tier. | building |
| `ERC8004ReputationFee` | Sets the fee tier from the swapper's on-chain agent reputation. | building |
| [`AgentBudget`](contracts/src/hooks/AgentBudgetHook.sol) | Enforces a signed per-epoch spend budget in the pool itself, so a delegated agent key is bounded by the venue rather than by its own code. | shipped |
| `IntentSettle` | Settles signed ERC-7683 intents against pool liquidity, with solvers competing on the fill. | building |
| `HookMeter` | Instruments another hook: gas, revert rate and fee take, published on-chain for anyone to audit. | building |
| `HookStack` | Runs an ordered stack of sub-hooks on one pool, each with its own gas budget. | building |

### Time

| Hook | What it does | Status |
| --- | --- | --- |
| `ExpirySettle` | Gives a pool a maturity date at which it settles, turning it into a dated instrument. | building |
| `VestedBuy` | Vests purchases linearly and enforces the schedule at the pool rather than in a token contract. | building |
| `EpochRebalance` | Rebalances the pool toward a target weight each epoch, making the pool itself an index. | building |
| `StreamDCA` | Executes recurring dollar-cost-average streams block by block. | building |
| [`TradingCalendar`](contracts/src/hooks/TradingCalendarHook.sol) | Opens and closes the pool on a schedule, ramping fees at the edges instead of slamming shut. | shipped |

### Cross-domain and information

| Hook | What it does | Status |
| --- | --- | --- |
| `SharedLiquidity` | Mirrors one pool across chains and settles the net position, so liquidity is not fragmented per chain. | building |
| `L1Anchor` | Anchors an L2 pool to a proven L1 price. | building |
| `VarianceSwap` | Pays realized variance, making liquidity providers short volatility and traders long it, explicitly. | building |
| `ImpliedVolFee` | Prices swaps off an implied-volatility surface rather than a realized-volatility estimate. | building |
| [`AntiSnipeRamp`](contracts/src/hooks/AntiSnipeRampHook.sol) | Starts a launch at a punitive fee that decays to normal, paying the difference to liquidity providers rather than the deployer. | shipped |
| `CommitRevealDark` | Hides order size behind a hash commitment and clears the batch on reveal. | building |
| `LotteryFees` | Sends a slice of fees to a no-loss lottery among the pool's liquidity providers. | building |
| `ReserveStable` | Mints and burns against a reserve to hold a band, with the band enforced by the hook. | building |

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
