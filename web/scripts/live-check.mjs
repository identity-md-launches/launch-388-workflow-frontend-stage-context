import { readFile, writeFile } from 'node:fs/promises';
import { createPublicClient, http, encodeAbiParameters, parseAbiParameters, keccak256 } from 'viem';

const root = new URL('../../', import.meta.url);
const config = JSON.parse(await readFile(new URL('dist/imd-deployment.json', root), 'utf8'));
const report = { checkedAt: new Date().toISOString(), operation: 'Read-only chain ID and contract bytecode; no transactions', endpoints: [] };
for (const url of config.network.rpcUrls) {
  const entry = { url };
  try {
    const client = createPublicClient({ transport: http(url, { timeout: 10000, retryCount: 0 }) });
    entry.chainId = await client.getChainId();
    if (entry.chainId !== config.chainId) throw Error('Chain ID mismatch');
    const targets = [...config.contracts, { name: 'PoolSwapTest', address: config.poolSwapTest }, ...['poolManager', 'quoter', 'stateView'].map(name => ({ name, address: config.network.uniswapV4[name] }))];
    entry.contracts = await Promise.all(targets.map(async c => {
      const code = await client.getCode({ address: c.address });
      return { name: c.name, address: c.address, nonemptyCode: !!code && code !== '0x' };
    }));
    entry.status = entry.contracts.every(c => c.nonemptyCode) ? 'passed' : 'failed';
  } catch (e) { entry.status = 'unverified'; entry.error = (e.shortMessage || e.message).slice(0, 350); entry.details = (e.details || '').slice(0, 200); }
  report.endpoints.push(entry);
}
try {
  const client = createPublicClient({ transport: http(config.network.rpcUrls[0], { timeout: 10000, retryCount: 0 }) });
  const abis = {};
  for (const c of config.contracts) abis[c.name] = JSON.parse(await readFile(new URL(`dist/${c.abiPath}`, root), 'utf8'));
  for (const [name,path] of Object.entries(config.protocolAbis)) abis[name] = JSON.parse(await readFile(new URL(`dist/${path}`, root), 'utf8'));
  const hook = config.contracts.find(c => c.name === config.hook.contract), token = config.contracts.find(c => c.name === config.token.contract);
  const key = { currency0: config.pool.pairedCurrency, currency1: token.address, fee: config.pool.fee, tickSpacing: config.pool.tickSpacing, hooks: hook.address };
  const poolId = keccak256(encodeAbiParameters(parseAbiParameters('address,address,uint24,int24,address'), Object.values(key)));
  const pool = { poolId };
  for (const name of ['accrued','totalCollected','totalDonated']) pool[name] = await client.readContract({ address:hook.address,abi:abis[hook.name],functionName:name,args:[poolId] });
  pool.slot0 = await client.readContract({ address:config.network.uniswapV4.stateView,abi:abis.StateView,functionName:'getSlot0',args:[poolId] });
  pool.liquidity = await client.readContract({ address:config.network.uniswapV4.stateView,abi:abis.StateView,functionName:'getLiquidity',args:[poolId] });
  pool.hookManager = await client.readContract({ address:hook.address,abi:abis[hook.name],functionName:'poolManager' });
  pool.routerManager = await client.readContract({ address:config.poolSwapTest,abi:abis.PoolSwapTest,functionName:'manager' });
  pool.decimals = await client.readContract({ address:token.address,abi:abis[token.name],functionName:'decimals' });
  pool.feeBps = await client.readContract({ address:hook.address,abi:abis[hook.name],functionName:'FEE_BPS' });
  pool.quotes = [];
  for (const [direction, amount] of [['buy',100000000000000n],['sell',1000000000000000000n]]) {
    try {
      const q = await client.simulateContract({ address:config.network.uniswapV4.quoter,abi:abis.V4Quoter,functionName:'quoteExactInputSingle',args:[{poolKey:key,zeroForOne:direction==='buy',exactAmount:amount,hookData:'0x'}] });
      pool.quotes.push({ direction, amount, result:q.result, status:'passed' });
    } catch (e) { pool.quotes.push({ direction, amount, status:'unverified', error:e.shortMessage || e.message }); }
  }
  report.pool = pool;
} catch (e) { report.pool = { status:'unverified', error:e.shortMessage || e.message }; }
const json = JSON.stringify(report, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2);
await writeFile(new URL('docs/evidence/live-rpc.json', root), json + '\n');
console.log(json);
if (!report.endpoints.some(e => e.status === 'passed')) console.log('Live deployment verification unavailable. This is not a successful chain verification.');
