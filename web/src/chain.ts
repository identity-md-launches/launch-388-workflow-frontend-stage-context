import { createPublicClient, createWalletClient, custom, fallback, http, formatUnits, type Address, type EIP1193Provider, type Hex } from 'viem';
import type { Config } from './config';
import { feeOn, priceLimit, unpackDelta } from './math';

export type Provider = EIP1193Provider & { on?: (event: string, fn: (...args: unknown[]) => void) => void; removeListener?: (event: string, fn: (...args: unknown[]) => void) => void };
declare global { interface Window { ethereum?: Provider } }
export function clients(config: Config, provider?: Provider, walletChain?: number) {
  const transports = config.deployment.network.rpcUrls.map(url => http(url, { timeout: 10000, retryCount: 0 }));
  return createPublicClient({ chain: config.chain, transport: fallback([...transports, ...(provider && walletChain === config.chain.id ? [custom(provider, { retryCount: 0 })] : [])], { retryCount: 0 }) });
}
export type Client = ReturnType<typeof clients>;
export async function switchChain(provider: Provider, config: Config) {
  const params: [{ chainId: Hex }] = [{ chainId: config.deployment.walletAddChain.chainId }];
  try { await provider.request({ method: 'wallet_switchEthereumChain', params }); }
  catch (error) {
    const e = error as { code?: number; message?: string; data?: { originalError?: { code?: number } } };
    if (e.code !== 4902 && e.data?.originalError?.code !== 4902 && !/unknown chain|unrecognized chain|not added/i.test(e.message ?? '')) throw error;
    await provider.request({ method: 'wallet_addEthereumChain', params: [config.deployment.walletAddChain] });
    await provider.request({ method: 'wallet_switchEthereumChain', params });
  }
}
export async function assertWallet(provider: Provider, config: Config, account: Address) {
  const [chain, accounts] = await Promise.all([provider.request({ method: 'eth_chainId' }), provider.request({ method: 'eth_accounts' })]);
  if (Number(chain) !== config.chain.id || accounts[0]?.toLowerCase() !== account.toLowerCase()) throw Error('Wallet account or network changed. Reconnect and review the action.');
}
export async function verifyDeployment(client: Client, config: Config) {
  if (await client.getChainId() !== config.chain.id) throw Error('RPC returned the wrong network. Transactions are disabled.');
  const targets = [...config.deployment.contracts.map(c => c.address), config.deployment.poolSwapTest, ...['poolManager', 'quoter', 'stateView'].map(k => config.deployment.network.uniswapV4[k as 'poolManager'])];
  const codes = await Promise.all(targets.map(address => client.getCode({ address })));
  if (codes.some(code => !code || code === '0x')) throw Error('A configured contract has no code. Transactions are disabled.');
  const [hookManager, routerManager] = await Promise.all([
    client.readContract({ address: config.hook.address, abi: config.abis[config.hook.name], functionName: 'poolManager' }),
    client.readContract({ address: config.deployment.poolSwapTest, abi: config.abis.PoolSwapTest, functionName: 'manager' }),
  ]) as [Address, Address];
  if ([hookManager, routerManager].some(a => a.toLowerCase() !== config.deployment.network.uniswapV4.poolManager.toLowerCase())) throw Error('PoolManager binding does not match the deployment.');
}
export async function snapshot(client: Client, config: Config, account?: Address) {
  await verifyDeployment(client, config);
  const block = await client.getBlockNumber();
  const hookRead = (name: string) => client.readContract({ address: config.hook.address, abi: config.abis[config.hook.name], functionName: name, args: [config.poolId], blockNumber: block });
  const tokenRead = (name: string, args: readonly unknown[] = []) => client.readContract({ address: config.token.address, abi: config.abis[config.token.name], functionName: name, args, blockNumber: block });
  const [accrued, collected, donated, slot, liquidity, decimals, feeBps, nativeBalance, tokenBalance, allowance] = await Promise.all([
    hookRead('accrued'), hookRead('totalCollected'), hookRead('totalDonated'),
    client.readContract({ address: config.deployment.network.uniswapV4.stateView, abi: config.abis.StateView, functionName: 'getSlot0', args: [config.poolId], blockNumber: block }),
    client.readContract({ address: config.deployment.network.uniswapV4.stateView, abi: config.abis.StateView, functionName: 'getLiquidity', args: [config.poolId], blockNumber: block }),
    tokenRead('decimals'), client.readContract({ address: config.hook.address, abi: config.abis[config.hook.name], functionName: 'FEE_BPS', blockNumber: block }),
    account ? client.getBalance({ address: account, blockNumber: block }) : undefined,
    account ? tokenRead('balanceOf', [account]) : undefined,
    account ? tokenRead('allowance', [account, config.deployment.poolSwapTest]) : undefined,
  ]);
  if (Number(decimals) !== config.deployment.token.decimals || feeBps !== 50n) throw Error('Token decimals or hook fee differs from the accepted implementation.');
  const sqrtPriceX96 = (slot as readonly [bigint, number, number, number])[0];
  return { accrued: accrued as bigint, collected: collected as bigint, donated: donated as bigint, sqrtPriceX96, liquidity: liquidity as bigint, decimals: Number(decimals), block, nativeBalance, tokenBalance: tokenBalance as bigint | undefined, allowance: allowance as bigint | undefined, updated: Date.now() };
}
export type Snapshot = Awaited<ReturnType<typeof snapshot>>;
export async function donations(client: Client, config: Config, block: bigint) {
  const start = block - 4999n > BigInt(config.deployment.deploymentBlock) ? block - 4999n : BigInt(config.deployment.deploymentBlock);
  const event = config.abis[config.hook.name].find(item => item.type === 'event' && item.name === 'FeesDonated');
  if (!event || event.type !== 'event') throw Error('Donation event is missing from the ABI.');
  const logs = await client.getLogs({ address: config.hook.address, event, args: { poolId: config.poolId }, fromBlock: start, toBlock: block });
  return { fromBlock: start, rows: logs.slice(-5).reverse().map(log => ({ hash: log.transactionHash!, block: log.blockNumber!, amount: (log.args as { amount: bigint }).amount })) };
}
export type DonationHistory = Awaited<ReturnType<typeof donations>>;
export async function quote(client: Client, config: Config, amount: bigint, buy: boolean, bps: number) {
  const slot = await client.readContract({ address: config.deployment.network.uniswapV4.stateView, abi: config.abis.StateView, functionName: 'getSlot0', args: [config.poolId] }) as readonly [bigint, number, number, number];
  if (slot[0] === 0n) throw Error('The pool is not initialized. Quotes are unavailable.');
  const result = await client.simulateContract({ address: config.deployment.network.uniswapV4.quoter, abi: config.abis.V4Quoter, functionName: 'quoteExactInputSingle', args: [{ poolKey: config.key, zeroForOne: buy, exactAmount: amount, hookData: '0x' }] });
  const output = (result.result as readonly [bigint, bigint])[0];
  if (output <= 0n) throw Error('The quote returns no output. Try another amount.');
  return { amount, buy, bps, output, limit: priceLimit(slot[0], bps, buy), price: slot[0], fee: buy ? feeOn(amount) : (output * 50n + 9949n) / 9950n, time: Date.now() };
}
export type Quote = Awaited<ReturnType<typeof quote>>;
export async function submit(config: Config, client: Client, provider: Provider, account: Address, action: 'donate' | 'approve' | 'swap', currentQuote?: Quote) {
  await assertWallet(provider, config, account);
  await verifyDeployment(client, config);
  const wallet = createWalletClient({ account, chain: config.chain, transport: custom(provider) });
  let request;
  if (action === 'donate') {
    request = (await client.simulateContract({ account, address: config.hook.address, abi: config.abis[config.hook.name], functionName: 'donateFees', args: [config.key] })).request;
  } else {
    if (!currentQuote || Date.now() - currentQuote.time > 45000) throw Error('This quote expired. Request a fresh quote and review it.');
    const q = currentQuote;
    if (action === 'approve') {
      if (q.buy) throw Error('ETH swaps need no token approval.');
      request = (await client.simulateContract({ account, address: config.token.address, abi: config.abis[config.token.name], functionName: 'approve', args: [config.deployment.poolSwapTest, q.amount] })).request;
    } else {
      const result = await client.simulateContract({ account, address: config.deployment.poolSwapTest, abi: [...config.abis.PoolSwapTest, ...config.abis[config.hook.name].filter(x => x.type === 'error')], functionName: 'swap', args: [config.key, { zeroForOne: q.buy, amountSpecified: -q.amount, sqrtPriceLimitX96: q.limit }, { takeClaims: false, settleUsingBurn: false }, '0x'], value: q.buy ? q.amount : 0n });
      const [delta0, delta1] = unpackDelta(result.result as bigint);
      const output = q.buy ? delta1 : delta0;
      const input = -(q.buy ? delta0 : delta1);
      if (input <= 0n || input > q.amount || output <= 0n) throw Error('The simulation returned an invalid swap. Request a new quote.');
      if (output < q.output * BigInt(10000 - q.bps) / 10000n) throw Error('The simulation output fell below your quote tolerance. Reduce the amount or refresh the quote.');
      request = result.request;
    }
  }
  await assertWallet(provider, config, account);
  if (currentQuote && Date.now() - currentQuote.time > 45000) throw Error('The quote expired during simulation. Refresh it before signing.');
  return wallet.writeContract(request);
}
export function spotPrice(state: Snapshot): string {
  const scaled = state.sqrtPriceX96 * state.sqrtPriceX96 * 10n ** 18n / (1n << 192n);
  return Number(formatUnits(scaled, state.decimals)).toLocaleString('en-US', { maximumFractionDigits: 2 });
}
export type Transaction = { hash: Hex; action: string; pending: boolean; failed?: boolean };
