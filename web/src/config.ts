import { keccak256, toBytes, encodeAbiParameters, parseAbiParameters, defineChain, isAddress } from 'viem';
import type { Abi, Address, Hex } from 'viem';

export interface Deployment {
  version: number; launchId: string; chainId: number; sourceCommit: string; attestationHash: string;
  contracts: { name: string; address: Address; abiHash: string; abiPath: string }[];
  network: { chainId: number; name: string; testnet: boolean; rpcUrls: string[]; explorer: string; nativeCurrency: { name: string; symbol: string; decimals: number }; faucets: string[]; uniswapV4: Record<'poolManager' | 'universalRouter' | 'quoter' | 'stateView' | 'positionManager' | 'permit2', Address> };
  walletAddChain: { chainId: Hex; chainName: string; rpcUrls: string[]; nativeCurrency: { name: string; symbol: string; decimals: number }; blockExplorerUrls: string[] };
  pool: { fee: number; tickSpacing: number; pairedCurrency: Address };
  token: { contract: string; name: string; symbol: string; decimals: number };
  hook: { contract: string }; poolSwapTest: Address; deploymentBlock: number;
  protocolAbis: Record<'PoolSwapTest' | 'StateView' | 'V4Quoter', string>;
  assets: { path: string; sha256: string }[];
}
export function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [k, canonical(v)]));
  return value;
}
async function json(path: string) {
  if (!/^[a-zA-Z0-9_./-]+$/.test(path) || path.includes('..') || path.startsWith('/')) throw Error('Unsafe deployment asset path.');
  const response = await fetch(new URL(path, document.baseURI), { cache: 'no-cache' });
  if (!response.ok) throw Error(`Could not load ${path}. Reload the page to retry.`);
  return response.json();
}
export async function loadConfig() {
  const deployment = await json('imd-deployment.json') as Deployment;
  if (deployment.version !== 1 || deployment.network.chainId !== deployment.chainId || Number(deployment.walletAddChain.chainId) !== deployment.chainId) throw Error('Deployment network does not match. Actions are unavailable.');
  const abis: Record<string, Abi> = {};
  await Promise.all(deployment.contracts.map(async c => {
    const abi = await json(c.abiPath);
    if (!isAddress(c.address) || !Array.isArray(abi) || keccak256(toBytes(JSON.stringify(canonical(abi)))).slice(2) !== c.abiHash) throw Error(`ABI verification failed for ${c.name}.`);
    abis[c.name] = abi;
  }));
  await Promise.all(Object.entries(deployment.protocolAbis).map(async ([name, path]) => { abis[name] = await json(path); }));
  const token = deployment.contracts.find(c => c.name === deployment.token.contract);
  const hook = deployment.contracts.find(c => c.name === deployment.hook.contract);
  if (!token || !hook || !isAddress(deployment.poolSwapTest)) throw Error('Deployment is incomplete.');
  const key = { currency0: deployment.pool.pairedCurrency, currency1: token.address, fee: deployment.pool.fee, tickSpacing: deployment.pool.tickSpacing, hooks: hook.address };
  const poolId = keccak256(encodeAbiParameters(parseAbiParameters('address, address, uint24, int24, address'), [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks]));
  const chain = defineChain({ id: deployment.chainId, name: deployment.network.name, nativeCurrency: deployment.network.nativeCurrency, rpcUrls: { default: { http: deployment.network.rpcUrls } }, blockExplorers: { default: { name: 'Explorer', url: deployment.network.explorer } }, testnet: deployment.network.testnet });
  return { deployment, abis, token, hook, key, poolId, chain };
}
export type Config = Awaited<ReturnType<typeof loadConfig>>;
