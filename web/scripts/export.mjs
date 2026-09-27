import { readFile, writeFile, mkdir, readdir, stat } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { resolve, relative } from 'node:path';
import { keccak256, toBytes, parseAbi } from 'viem';

const root = fileURLToPath(new URL('../../', import.meta.url));
const read = async path => JSON.parse(await readFile(resolve(root, path), 'utf8'));
const canonical = value => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(k => [k, canonical(value[k])])) : value;
const hashAbi = abi => keccak256(toBytes(JSON.stringify(canonical(abi)))).slice(2);
const handoff = await read('web/config/deployment.json');
const net = await read('web/config/network.json');
const workflow = await read('web/config/workflow.json');
if (handoff.chainId !== net.network.chainId || parseInt(net.walletAddChain.chainId, 16) !== handoff.chainId) throw Error('Chain configuration mismatch');
// Pinned inputs disappear after submission. The reviewed copies remain rebuildable.
for (const name of ['deployment', 'network']) {
  try {
    const supplied = await read(`.imd/reads/${name}.json`);
    if (JSON.stringify(canonical(supplied)) !== JSON.stringify(canonical(await read(`web/config/${name}.json`)))) throw Error(`${name} differs from handoff`);
  } catch (e) { if (e.code !== 'ENOENT') throw e; }
}
const contractFiles = [];
for (const contract of handoff.contracts) {
  const path = `docs/abi/${contract.name}.json`;
  const pinned = execFileSync('git', ['show', `${handoff.sourceCommit}:${path}`], { cwd: root });
  const abi = JSON.parse(pinned);
  if (!Array.isArray(abi) || hashAbi(abi) !== contract.abiHash) throw Error(`Pinned ABI hash mismatch: ${contract.name}`);
  if (hashAbi(await read(path)) !== contract.abiHash) throw Error(`Delivered ABI differs from pinned source: ${contract.name}`);
  contractFiles.push({ path: `abi/${contract.name}.json`, bytes: pinned });
}
const pool = '(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)';
const protocols = {
  PoolSwapTest: parseAbi([
    `function swap(${pool} key, (bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) params, (bool takeClaims, bool settleUsingBurn) testSettings, bytes hookData) payable returns (int256 delta)`,
    'function manager() view returns (address)',
    'error NoSwapOccurred()',
  ]),
  StateView: parseAbi(['function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)', 'function getLiquidity(bytes32 poolId) view returns (uint128 liquidity)']),
  V4Quoter: parseAbi([`function quoteExactInputSingle((${pool} poolKey, bool zeroForOne, uint128 exactAmount, bytes hookData) params) returns (uint256 amountOut, uint256 gasEstimate)`]),
};
const protocolFiles = Object.entries(protocols).map(([name, abi]) => ({ path: `abi/${name}.json`, bytes: Buffer.from(JSON.stringify(abi, null, 2) + '\n') }));
const config = {
  version: 1,
  launchId: handoff.launchId,
  chainId: handoff.chainId,
  sourceCommit: handoff.sourceCommit,
  attestationHash: handoff.attestationHash,
  contracts: handoff.contracts.map(({ name, address, abiHash }) => ({ name, address, abiHash, abiPath: `abi/${name}.json` })),
  network: net.network,
  walletAddChain: net.walletAddChain,
  pool: handoff.manifest.pool,
  token: handoff.manifest.token,
  hook: { contract: handoff.manifest.hook.contract },
  poolSwapTest: workflow.poolSwapTest,
  protocolAbis: Object.fromEntries(protocolFiles.map(f => [f.path.split('/')[1].replace('.json', ''), f.path])),
  deploymentBlock: Math.min(...handoff.contracts.map(c => c.blockNumber)),
};
const checking = process.argv.includes('--check');
await mkdir(resolve(root, 'dist/abi'), { recursive: true });
for (const f of [...contractFiles, ...protocolFiles]) {
  if (checking) {
    if (!f.bytes.equals(await readFile(resolve(root, 'dist', f.path)))) throw Error(`Export differs: ${f.path}`);
  } else await writeFile(resolve(root, 'dist', f.path), f.bytes);
}
async function inventory(dir) {
  const list = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = resolve(dir, entry.name);
    if (entry.isSymbolicLink()) throw Error('Export may not contain symlinks');
    if (entry.isDirectory()) list.push(...await inventory(path));
    else if (relative(resolve(root, 'dist'), path) !== 'imd-deployment.json') {
      const bytes = await readFile(path);
      if (bytes.length > 8388608) throw Error(`Asset too large: ${path}`);
      list.push({ path: relative(resolve(root, 'dist'), path), sha256: createHash('sha256').update(bytes).digest('hex') });
    }
  }
  return list.sort((a,b) => a.path.localeCompare(b.path));
}
config.assets = await inventory(resolve(root, 'dist'));
if (config.assets.length > 128 || !config.assets.some(a => a.path === 'index.html')) throw Error('Invalid export inventory');
const total = (await Promise.all(config.assets.map(a => stat(resolve(root, 'dist', a.path))))).reduce((n,s) => n+s.size, 0);
if (total > 8 * 1024 * 1024) throw Error('Export leaves no room in submission budget');
if (checking) {
  if (JSON.stringify(canonical(config)) !== JSON.stringify(canonical(await read('dist/imd-deployment.json')))) throw Error('Stale deployment manifest');
} else await writeFile(resolve(root, 'dist/imd-deployment.json'), JSON.stringify(config, null, 2) + '\n');
console.log(`${checking ? 'Verified' : 'Exported'} ${config.assets.length} assets, ${total} bytes; both pinned canonical Keccak ABI hashes match; network and handoff match.`);
