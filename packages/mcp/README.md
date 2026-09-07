# @hookforge/mcp

An MCP server that puts the Uniswap v4 hook catalogue inside your coding agent.

Ask it "how do I stop my pool being drained during a depeg" and it answers with a named hook, its parameters, the
prior art it improves on, and the case where it will not help you. Point it at any hook address on any chain and it
tells you which callbacks Uniswap will actually invoke, without an RPC and without needing the source to be verified.

## Install

Claude Code:

```bash
claude mcp add hookforge -- npx -y @hookforge/mcp
```

Any MCP client, via config:

```json
{
  "mcpServers": {
    "hookforge": { "command": "npx", "args": ["-y", "@hookforge/mcp"] }
  }
}
```

No API key, no network access, no telemetry. The catalogue ships inside the package.

## Tools

| Tool | Use it for |
| --- | --- |
| `search_hooks` | The problem in plain language, ranked matches back, with the terms that matched so you can see the reasoning. Start here. |
| `list_hooks` | The whole catalogue, filtered by tag, family or chain, plus the full taxonomy. |
| `get_hook` | One hook in full: mechanism, prior art, **limitation**, parameters, permissions, errors, addresses, optionally the ABI. |
| `decode_hook_address` | What a hook address will do, decoded from the address itself. Works for hooks nobody has published. |
| `get_deployment` | A hook's address on a chain, and that chain's `PoolManager`. |
| `list_chains` | Every chain with a Uniswap v4 deployment HookForge knows about. |

## Why `decode_hook_address` works without a network

Uniswap v4 decides which callbacks to invoke by masking the low fourteen bits of the hook's address. Those bits are
not metadata, they are the mechanism. So the permissions returned here are what the protocol will actually do, for any
hook, on any chain, whether or not it published an ABI or verified its source. Absence from the catalogue means only
that HookForge did not publish that hook; it is not a safety judgement, and the tool says so in its own output.

## Ranking

`search_hooks` uses a transparent keyword score (tag matches weigh most, then name, family, summary) and returns the
matched terms alongside each result. An embedding index would score better on recall, but an agent recommending a
financial mechanism should be able to show its work, and the catalogue is small enough that it does not need one.
