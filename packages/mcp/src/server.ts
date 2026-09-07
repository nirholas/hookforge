#!/usr/bin/env node
/**
 * HookForge MCP server.
 *
 * Gives a coding agent the same view of the Uniswap v4 hook catalogue a developer gets from the website: search by
 * the problem rather than the name, read a hook's parameters, prior art and limitations, resolve its address on a
 * chain, and decode what any hook address on any chain will actually do.
 *
 * Run it with `npx @hookforge/mcp`, or wire it into a client:
 *
 *   { "mcpServers": { "hookforge": { "command": "npx", "args": ["-y", "@hookforge/mcp"] } } }
 */
import {McpServer} from "@modelcontextprotocol/sdk/server/mcp.js";
import {StdioServerTransport} from "@modelcontextprotocol/sdk/server/stdio.js";
import {z} from "zod";

import {chains, loadManifest, permissionsFromAddress, registry, searchHooks} from "./catalogue.js";

const server = new McpServer({name: "hookforge", version: "1.0.0"});

/** Every tool returns JSON text: agents parse it reliably, and a human reading a transcript can still follow it. */
const json = (value: unknown) => ({content: [{type: "text" as const, text: JSON.stringify(value, null, 2)}]});

server.tool(
  "search_hooks",
  "Find Uniswap v4 hooks by the problem you are solving, in plain language. Use this first: it is the fastest way from 'my pool keeps getting arbitraged after quiet periods' to a named hook. Returns ranked matches with the terms that matched, so you can see why.",
  {
    query: z.string().describe("The problem in plain language, e.g. 'stop snipers in the first block of a launch'."),
    limit: z.number().int().min(1).max(20).default(5).describe("How many matches to return."),
  },
  async ({query, limit}) => {
    const results = searchHooks(query, limit);
    if (results.length === 0) {
      return json({
        query,
        matches: [],
        hint: "No keyword matched. Try list_hooks to see every hook and its family, or search a mechanism word such as 'fee', 'peg', 'launch', 'mev' or 'risk'.",
      });
    }

    return json({
      query,
      matches: results.map(({entry, score, matched}) => ({
        slug: entry.slug,
        name: entry.name,
        family: entry.family,
        summary: entry.summary,
        tags: entry.tags,
        docs: entry.docs,
        score,
        matched,
      })),
    });
  },
);

server.tool(
  "list_hooks",
  "List the whole HookForge catalogue, optionally filtered by tag, family, or the chain a hook is deployed on. Use when you want the shape of what exists rather than an answer to one question.",
  {
    tag: z.string().optional().describe("Filter by tag, e.g. 'mev', 'risk', 'dynamic-fee', 'oracle-free'."),
    family: z.string().optional().describe("Filter by family, e.g. 'Risk' or 'Order flow and MEV'."),
    chainId: z.number().int().optional().describe("Only hooks with a published deployment on this chain id."),
  },
  async ({tag, family, chainId}) => {
    const hooks = registry.hooks.filter((hook) => {
      if (tag && !hook.tags.includes(tag)) return false;
      if (family && hook.family !== family) return false;
      if (chainId && !hook.deployments.some((d) => d.chainId === chainId)) return false;
      return true;
    });

    return json({
      count: hooks.length,
      total: registry.count,
      families: [...new Set(registry.hooks.map((hook) => hook.family))].sort(),
      tags: [...new Set(registry.hooks.flatMap((hook) => hook.tags))].sort(),
      hooks: hooks.map((hook) => ({
        slug: hook.slug,
        name: hook.name,
        family: hook.family,
        summary: hook.summary,
        tags: hook.tags,
        docs: hook.docs,
      })),
    });
  },
);

server.tool(
  "get_hook",
  "Everything about one hook: what it does and why, the prior art it is measured against, where it does NOT help, its per-pool parameters, its callback permissions, its custom errors and its addresses. Read the 'limitation' field before recommending a hook to anyone.",
  {
    slug: z.string().describe("The hook slug, e.g. 'circuit-breaker'. Get slugs from search_hooks or list_hooks."),
    includeAbi: z.boolean().default(false).describe("Include the full ABI. Large; only ask when you will encode a call."),
  },
  async ({slug, includeAbi}) => {
    const manifest = loadManifest(slug);
    if (!manifest) {
      return json({
        error: `No hook with slug '${slug}'.`,
        available: registry.hooks.map((hook) => hook.slug),
      });
    }

    const {abi, ...rest} = manifest;
    return json(includeAbi ? {...rest, abi} : rest);
  },
);

server.tool(
  "decode_hook_address",
  "Decode which Uniswap v4 callbacks an address will receive, from the address alone. Works offline for ANY hook on any chain, verified source or not, because v4 masks the low fourteen bits of the address to decide what to call. Also says whether the address is one of ours.",
  {address: z.string().regex(/^0x[0-9a-fA-F]{40}$/).describe("The hook address from a PoolKey.")},
  async ({address}) => {
    const permissions = permissionsFromAddress(address);
    const known = registry.hooks.find((hook) =>
      hook.deployments.some((d) => d.address.toLowerCase() === address.toLowerCase()),
    );

    return json({
      address,
      isHook: BigInt(address) !== 0n,
      permissions,
      callbacks: Object.entries(permissions)
        .filter(([, enabled]) => enabled)
        .map(([name]) => name),
      inCatalogue: known ? {slug: known.slug, name: known.name, docs: known.docs} : null,
      note: "Permissions come from the address bits and are authoritative. Absence from the catalogue means only that HookForge did not publish this hook, not that it is unsafe.",
    });
  },
);

server.tool(
  "get_deployment",
  "Resolve a hook's contract address on a chain, and the Uniswap v4 PoolManager for that chain.",
  {
    slug: z.string().describe("The hook slug."),
    chainId: z.number().int().describe("Chain id, e.g. 8453 for Base, 42161 for Arbitrum, 4663 for Robinhood Chain."),
  },
  async ({slug, chainId}) => {
    const entry = registry.hooks.find((hook) => hook.slug === slug);
    const chain = chains.find((c) => c.chainId === chainId);
    const deployment = entry?.deployments.find((d) => d.chainId === chainId);

    return json({
      slug,
      chainId,
      chain: chain?.slug ?? null,
      poolManager: chain?.poolManager ?? null,
      address: deployment?.address ?? null,
      available: entry?.deployments.map((d) => ({chain: d.chain, chainId: d.chainId})) ?? [],
      error: entry ? undefined : `No hook with slug '${slug}'.`,
    });
  },
);

server.tool(
  "list_chains",
  "Every chain HookForge knows a Uniswap v4 PoolManager on, with its chain id and manager address.",
  {},
  async () => json({count: chains.length, chains}),
);

await server.connect(new StdioServerTransport());
