import {test} from "node:test";
import assert from "node:assert/strict";

import {
  poolId,
  permissionsFromAddress,
  isHook,
  listHooks,
  getHookEntry,
  hookAddress,
  findHooks,
  loadManifest,
  dynamicFeePoolKey,
  sortCurrencies,
  formatFee,
  DYNAMIC_FEE_FLAG,
} from "../dist/index.js";

test("poolId matches Solidity's keccak256(abi.encode(key))", () => {
  // Ground truth from `cast keccak $(cast abi-encode "f((address,address,uint24,int24,address))" ...)`, which is what
  // PoolIdLibrary.toId computes. If this ever drifts, every read in the SDK silently targets the wrong pool.
  const id = poolId({
    currency0: "0x1111111111111111111111111111111111111111",
    currency1: "0x2222222222222222222222222222222222222222",
    fee: 3000,
    tickSpacing: 60,
    hooks: "0x3333333333333333333333333333333333335080",
  });
  assert.equal(id, "0x34161600ffd9d4f0718a2074107fee9f1005776be7e5c00867ddf1f92ab20ec0");
});

test("permissions decode from the low fourteen bits of a hook address", () => {
  // 0x1080 is AFTER_INITIALIZE (1 << 12) | BEFORE_SWAP (1 << 7): the shape every fee-overriding hook here has.
  const fee = permissionsFromAddress("0x0000000000000000000000000000000000001080");
  assert.equal(fee.afterInitialize, true);
  assert.equal(fee.beforeSwap, true);
  assert.equal(fee.afterSwap, false);
  assert.equal(fee.beforeInitialize, false);

  // 0x10c0 adds AFTER_SWAP (1 << 6), which is what the circuit breaker needs to see the price it produced.
  const breaker = permissionsFromAddress("0x00000000000000000000000000000000000010c0");
  assert.equal(breaker.afterSwap, true);
  assert.equal(breaker.beforeSwap, true);
  assert.equal(breaker.afterInitialize, true);
});

test("every published hook address encodes the permissions its manifest claims", async () => {
  for (const entry of listHooks()) {
    const manifest = await loadManifest(entry.slug);
    if (!manifest.permissions) continue;

    for (const deployment of manifest.deployments) {
      const decoded = permissionsFromAddress(deployment.address);
      assert.deepEqual(
        decoded,
        manifest.permissions,
        `${entry.slug} on ${deployment.chain} does not encode its declared permissions`,
      );
    }
  }
});

test("the zero address is not a hook", () => {
  assert.equal(isHook("0x0000000000000000000000000000000000000000"), false);
  assert.equal(isHook("0x0000000000000000000000000000000000001080"), true);
});

test("the catalogue is queryable by slug, tag, family and chain", () => {
  const hooks = listHooks();
  assert.ok(hooks.length > 0, "the registry is empty; run the registry generator");

  const first = hooks[0];
  assert.equal(getHookEntry(first.slug)?.slug, first.slug);
  assert.equal(getHookEntry("no-such-hook"), undefined);

  for (const hook of findHooks({family: first.family})) assert.equal(hook.family, first.family);
  for (const hook of findHooks({chainId: 8453})) {
    assert.ok(hook.deployments.some((d) => d.chainId === 8453));
  }
  assert.deepEqual(findHooks({tag: "no-such-tag"}), []);
});

test("hookAddress resolves a deployment per chain", () => {
  const entry = listHooks().find((hook) => hook.deployments.length > 0);
  assert.ok(entry, "no hook has a published deployment");

  const deployment = entry.deployments[0];
  assert.equal(hookAddress(entry.slug, deployment.chainId), deployment.address);
  assert.equal(hookAddress(entry.slug, 999999), undefined);
});

test("a pool key for a fee hook sorts its currencies and sets the dynamic-fee flag", () => {
  const key = dynamicFeePoolKey(
    "0x2222222222222222222222222222222222222222",
    "0x1111111111111111111111111111111111111111",
    60,
    "0x3333333333333333333333333333333333335080",
  );
  assert.equal(key.currency0, "0x1111111111111111111111111111111111111111");
  assert.equal(key.currency1, "0x2222222222222222222222222222222222222222");
  assert.equal(key.fee, DYNAMIC_FEE_FLAG);
});

test("currency sorting is stable regardless of argument order", () => {
  const a = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const b = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  assert.deepEqual(sortCurrencies(a, b), sortCurrencies(b, a));
});

test("fees format as percentages", () => {
  assert.equal(formatFee(3000), "0.30%");
  assert.equal(formatFee(500), "0.05%");
  assert.equal(formatFee(1_000_000), "100.00%");
});
