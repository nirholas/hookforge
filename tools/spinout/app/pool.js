/**
 * The pool actions every demo needs: approve, mint from the faucet, and swap through the demo router.
 *
 * Shared rather than repeated per panel, because these are the three places a demo can lose somebody's money if it
 * is wrong, and three copies of them is three chances to get one wrong.
 */
import {formatUnits} from "viem";

export const ERC20_ABI = [
  {type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{type: "string"}]},
  {type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{type: "uint8"}]},
  {type: "function", name: "claim", stateMutability: "nonpayable", inputs: [], outputs: []},
  {type: "function", name: "balanceOf", stateMutability: "view", inputs: [{type: "address"}], outputs: [{type: "uint256"}]},
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [{type: "address"}, {type: "address"}],
    outputs: [{type: "uint256"}],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [{type: "address"}, {type: "uint256"}],
    outputs: [{type: "bool"}],
  },
];

export const ROUTER_ABI = [
  {
    type: "function",
    name: "swap",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "key",
        type: "tuple",
        components: [
          {name: "currency0", type: "address"},
          {name: "currency1", type: "address"},
          {name: "fee", type: "uint24"},
          {name: "tickSpacing", type: "int24"},
          {name: "hooks", type: "address"},
        ],
      },
      {
        name: "params",
        type: "tuple",
        components: [
          {name: "zeroForOne", type: "bool"},
          {name: "amountSpecified", type: "int256"},
          {name: "sqrtPriceLimitX96", type: "uint160"},
        ],
      },
      {name: "hookData", type: "bytes"},
    ],
    outputs: [{type: "int256"}],
  },
];

/** v4's own price bounds. A swap that does not want a limit still has to pass one on the correct side. */
export const MIN_SQRT_PRICE_LIMIT = 4295128740n;
export const MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341n;

export function poolKeyOf(deployment) {
  return {
    currency0: deployment.currency0,
    currency1: deployment.currency1,
    fee: deployment.fee,
    tickSpacing: deployment.tickSpacing,
    hooks: deployment.hook,
  };
}

/** Approves `spender` for `token` if the current allowance is short. Returns whether it sent a transaction. */
export async function ensureAllowance({publicClient, walletClient, account, token, spender, amount}) {
  const allowance = await publicClient.readContract({
    address: token,
    abi: ERC20_ABI,
    functionName: "allowance",
    args: [account, spender],
  });
  if (allowance >= amount) return false;

  const hash = await walletClient.writeContract({
    address: token,
    abi: ERC20_ABI,
    functionName: "approve",
    args: [spender, 2n ** 256n - 1n],
    account,
  });
  await publicClient.waitForTransactionReceipt({hash});
  return true;
}

/** Mints from both faucet tokens. */
export async function claimBoth({publicClient, walletClient, account, deployment}) {
  for (const token of [deployment.currency0, deployment.currency1]) {
    const hash = await walletClient.writeContract({
      address: token,
      abi: ERC20_ABI,
      functionName: "claim",
      account,
    });
    await publicClient.waitForTransactionReceipt({hash});
  }
}

/**
 * Swaps through the demo router, approving first if needed.
 *
 * Simulated before it is sent, and the receipt's status is checked after. Both matter and neither is the default.
 * Simulating first means a hook that refuses the swap does so for free, with its own error decoded, instead of the
 * visitor paying gas to be told no. Checking the receipt matters because a wallet client does not throw on a
 * reverted transaction: it hands back a receipt with `status: "reverted"`, so a demo that only awaited the receipt
 * would cheerfully report a refused swap as a success. That is exactly what this one did until a halted pool proved
 * otherwise.
 *
 * @returns The transaction hash.
 */
export async function swap({publicClient, walletClient, account, deployment, zeroForOne, amount, hookData = "0x"}) {
  const inputToken = zeroForOne ? deployment.currency0 : deployment.currency1;
  await ensureAllowance({publicClient, walletClient, account, token: inputToken, spender: deployment.router, amount});

  const call = {
    address: deployment.router,
    abi: ROUTER_ABI,
    functionName: "swap",
    args: [
      poolKeyOf(deployment),
      {
        zeroForOne,
        amountSpecified: -amount,
        sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT,
      },
      hookData,
    ],
    account,
  };

  // Throws with the contract's own custom error if anything would refuse this.
  await publicClient.simulateContract(call);

  const hash = await walletClient.writeContract(call);
  const receipt = await publicClient.waitForTransactionReceipt({hash});
  if (receipt.status !== "success") {
    throw new Error("The swap reverted on-chain. The pool refused it after the simulation passed.");
  }
  return hash;
}

/** Reads both of the pool's tokens: symbol, decimals, and the visitor's balance. */
export async function readPair(publicClient, deployment, account) {
  const read = (address, functionName, args) =>
    publicClient.readContract({address, abi: ERC20_ABI, functionName, args});

  const [symbol0, decimals0, symbol1, decimals1] = await Promise.all([
    read(deployment.currency0, "symbol"),
    read(deployment.currency0, "decimals"),
    read(deployment.currency1, "symbol"),
    read(deployment.currency1, "decimals"),
  ]);

  const [balance0, balance1] = account
    ? await Promise.all([
        read(deployment.currency0, "balanceOf", [account]),
        read(deployment.currency1, "balanceOf", [account]),
      ])
    : [0n, 0n];

  return {symbol0, decimals0, balance0, symbol1, decimals1, balance1};
}

export function formatToken(value, decimals, places = 4) {
  const text = formatUnits(value ?? 0n, decimals);
  const [whole, fraction = ""] = text.split(".");
  return fraction ? `${whole}.${fraction.slice(0, places)}` : whole;
}
