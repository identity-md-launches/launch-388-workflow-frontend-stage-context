import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { fileURLToPath } from 'node:url';
import { resolve, extname } from 'node:path';
import { decodeFunctionData, encodeFunctionResult, encodeAbiParameters, encodeEventTopics, parseAbiParameters } from 'viem';

export const root = fileURLToPath(new URL('../../', import.meta.url));
export const manifest = JSON.parse(await readFile(resolve(root, 'dist/imd-deployment.json'), 'utf8'));
const abis = (await Promise.all([...manifest.contracts.map(c => c.abiPath), ...Object.values(manifest.protocolAbis)].map(p => readFile(resolve(root, 'dist', p), 'utf8').then(JSON.parse)))).flat();
export const account = '0x1111111111111111111111111111111111111111';
export const transactionHash = `0x${'a'.repeat(64)}`;
export const outputBuy = 990n * 10n ** 18n, outputSell = 995n * 10n ** 12n;
export async function server() {
  const server = createServer(async (req, res) => {
    const pathname = decodeURIComponent(new URL(req.url, 'http://local').pathname);
    if (!pathname.startsWith('/preview/') || pathname.includes('..')) { res.writeHead(404).end(); return; }
    const path = resolve(root, 'dist', pathname.slice(9) || 'index.html');
    try { const bytes = await readFile(path); res.setHeader('Content-Type', ({ '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml' })[extname(path)] ?? 'application/octet-stream'); res.end(bytes); }
    catch { res.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return { url: `http://127.0.0.1:${server.address().port}/preview/`, close: () => new Promise(resolve => server.close(resolve)) };
}
export async function setup(page, options = {}) {
  const fixture = { reads: [], simulations: [], requests: [], receipts: [], accrued: 12345600000000000n, donated: 56000000000000000n, liquidity: 1000000000n, allowance: 0n, rpcFailure: false, emptyCode: false, revertSimulation: false, logsFail: false, pending: false, ...options };
  await page.addInitScript(({ account, transactionHash, options }) => {
    window.__walletCalls = [];
    window.__walletFixture = { chain: '0x1', connected: false, unknownChain: true, rejected: false, ...options };
    const listeners = {};
    window.ethereum = {
      on: (event, fn) => { (listeners[event] ??= []).push(fn); },
      removeListener: (event, fn) => { listeners[event] = listeners[event]?.filter(x => x !== fn); },
      request: async ({ method, params }) => {
        window.__walletCalls.push({ method, params });
        const f = window.__walletFixture;
        if (f.rejected && ['eth_requestAccounts', 'eth_sendTransaction', 'wallet_switchEthereumChain'].includes(method)) throw { code: 4001, message: 'User rejected the request' };
        if (method === 'eth_accounts') return f.connected ? [account] : [];
        if (method === 'eth_requestAccounts') { f.connected = true; return [account]; }
        if (method === 'eth_chainId') return f.chain;
        if (method === 'wallet_switchEthereumChain') { if (f.unknownChain) throw { code: 4902, message: 'Unknown chain' }; f.chain = params[0].chainId; listeners.chainChanged?.forEach(fn => fn(f.chain)); return null; }
        if (method === 'wallet_addEthereumChain') { f.unknownChain = false; return null; }
        if (method === 'eth_sendTransaction') { window.dispatchEvent(new CustomEvent('test-wallet-submit', { detail: params[0] })); return transactionHash; }
        throw Error(`Unexpected wallet request: ${method}`);
      },
    };
    window.__changeAccount = () => { window.__walletFixture.connected = false; listeners.accountsChanged?.forEach(fn => fn([])); };
  }, { account, transactionHash, options: { chain: options.chain ?? '0x1', unknownChain: options.unknownChain ?? true, connected: options.connected ?? false } });
  await page.exposeFunction('__recordSubmit', tx => {
    fixture.requests.push(tx);
    const decoded = decodeFunctionData({ abi: abis, data: tx.data });
    if (decoded.functionName === 'approve') fixture.allowance = decoded.args[1];
    if (decoded.functionName === 'donateFees') { fixture.donated += fixture.accrued; fixture.accrued = 0n; }
  });
  await page.addInitScript(() => window.addEventListener('test-wallet-submit', e => window.__recordSubmit(e.detail)));
  await page.route('https://**/*', async route => {
    if (fixture.rpcFailure) { await route.fulfill({ status: 503, body: 'Mock RPC unavailable' }); return; }
    const body = route.request().postDataJSON();
    if (!body) throw Error('Unexpected external request');
    const respond = async rpc => {
      fixture.reads.push(rpc);
      let result;
      switch (rpc.method) {
        case 'eth_chainId': result = `0x${manifest.chainId.toString(16)}`; break;
        case 'eth_getCode': result = fixture.emptyCode ? '0x' : '0x60006000'; break;
        case 'eth_blockNumber': result = '0xb71b00'; break;
        case 'eth_getBalance': result = '0x8ac7230489e80000'; break;
        case 'eth_getLogs': {
          if (fixture.logsFail) return { jsonrpc: '2.0', id: rpc.id, error: { code: -32000, message: 'Log query unavailable' } };
          const event = abis.find(x => x.type === 'event' && x.name === 'FeesDonated');
          result = [{ address: manifest.contracts.find(c => c.name === 'ETHOnlyFeeHook').address, blockHash: `0x${'b'.repeat(64)}`, blockNumber: '0xb71aff', transactionHash, transactionIndex: '0x0', logIndex: '0x0', removed: false, topics: encodeEventTopics({ abi: [event], eventName: 'FeesDonated', args: { poolId: rpc.params[0].topics[1] } }), data: encodeAbiParameters(parseAbiParameters('uint256'), [fixture.donated]) }];
          break;
        }
        case 'eth_getTransactionReceipt': {
          fixture.receipts.push(rpc.params[0]);
          result = fixture.pending ? null : { transactionHash, transactionIndex: '0x0', blockHash: `0x${'b'.repeat(64)}`, blockNumber: '0xb71b00', from: account, to: manifest.poolSwapTest, cumulativeGasUsed: '0x10000', gasUsed: '0x10000', effectiveGasPrice: '0x3b9aca00', contractAddress: null, logs: [], logsBloom: `0x${'0'.repeat(512)}`, status: '0x1', type: '0x2' }; break;
        }
        case 'eth_call': {
          const call = rpc.params[0];
          const { functionName, args = [] } = decodeFunctionData({ abi: abis, data: call.data });
          let value;
          const functions = {
            poolManager: manifest.network.uniswapV4.poolManager, manager: manifest.network.uniswapV4.poolManager,
            accrued: fixture.accrued, totalCollected: 68345600000000000n, totalDonated: fixture.donated,
            decimals: 18, FEE_BPS: 50n, getSlot0: [79299443975792720780679863727831n, 138180, 0, 3000],
            getLiquidity: fixture.liquidity, balanceOf: 1000000n * 10n ** 18n, allowance: fixture.allowance,
          };
          if (functionName in functions) value = functions[functionName];
          else if (functionName === 'quoteExactInputSingle') { fixture.simulations.push({ functionName, args, to: call.to }); value = [args[0].zeroForOne ? outputBuy : outputSell, 180000n]; }
          else if (['swap', 'donateFees', 'approve'].includes(functionName)) {
            fixture.simulations.push({ functionName, args, to: call.to, value: call.value });
            if (fixture.revertSimulation) return { jsonrpc: '2.0', id: rpc.id, error: { code: 3, message: 'execution reverted: PartialFill', data: '0x' } };
            if (functionName === 'swap') { const input = -args[1].amountSpecified; value = args[1].zeroForOne ? (-input << 128n) | outputBuy : (outputSell << 128n) | BigInt.asUintN(128, -input); }
            else value = functionName === 'approve' ? true : fixture.accrued;
          } else throw Error(`Unexpected contract call: ${functionName}`);
          result = encodeFunctionResult({ abi: abis, functionName, result: value }); break;
        }
        default: throw Error(`Unexpected RPC method ${rpc.method}`);
      }
      return { jsonrpc: '2.0', id: rpc.id, result };
    };
    try { await route.fulfill({ contentType: 'application/json', body: JSON.stringify(Array.isArray(body) ? await Promise.all(body.map(respond)) : await respond(body)) }); }
    catch (e) { console.error(e); await route.fulfill({ status: 500, body: e.message }); }
  });
  return fixture;
}
