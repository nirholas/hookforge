# Contributing

Hook ideas are welcome, especially ones this catalogue has missed. The prior-art check is the hard part and it is the
part that makes this repository worth reading, so an issue that says "this exists already, here is where" is as useful
as a new mechanism.

## Claiming a hook before you write it

More than one person (or agent) works in this repository at a time, and two people writing the same hook into the same
filename is a real failure mode rather than a theoretical one. Before writing a contract:

1. Check `README.md`. A row marked **shipped** is done. A row marked **building** is unclaimed unless it appears below.
2. Add the hook to the table in this file, in its own commit, and push that commit before you start. It is one line and
   it costs a few seconds; recovering somebody's overwritten work costs an afternoon.
3. If a file you did not create appears under `contracts/src/hooks/` while you are working, someone else is on it.
   Do not overwrite it. Take another row.

| Hook | Claimed by | Status |
| --- | --- | --- |
| `VestedBuy` | three-ws-62 | in progress |
| `StreamDCA` | three-ws-62 | queued |

## What a hook needs before it is done

- **A prior-art check.** Roughly 140 hooks and hackathon submissions have been published. Find the closest one and say
  in the contract's NatSpec what is actually different. If nothing is, do not write it.
- **A stated limitation.** Every hook has a case it does not help with. `@custom:limitation` is where that goes, and it
  ends up on the hook's page. A hook with no stated limitation has not been thought about hard enough.
- **The registry NatSpec tags**: `@custom:slug`, `@custom:family`, `@custom:prior-art`, `@custom:limitation`,
  `@custom:chains`. The whole site and SDK are generated from these, so a missing tag is a missing page.
- **Tests against a real `PoolManager`**, including at least one that asserts the mechanism changes what a swapper
  actually receives. A hook whose tests only check its own view functions has not been tested.
- **A clean `forge build`.** Warnings are errors here. If a cast is safe, say why in a `forge-lint` comment rather than
  leaving the warning for the next person to re-investigate.

```bash
cd contracts && forge build && forge test   # contracts
cd .. && npm run build:registry && npm test # registry, SDK, MCP
cd apps/web && npm run build                # the site, generated from the registry
```

## Style

Match what is already there. Prose in NatSpec explains *why the mechanism exists* before it explains what the code
does, because the code is readable and the reasoning is not. No em-dashes. No TODOs: if it is worth noting, it is worth
either doing or writing down as a limitation.
