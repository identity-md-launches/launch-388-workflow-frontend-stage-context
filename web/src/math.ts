import { formatUnits, parseUnits } from 'viem';

export const feeOn = (amount: bigint) => (amount * 50n + 9999n) / 10000n;
export function parseAmount(value: string, decimals: number): bigint {
  if (!/^(?:0|[1-9]\d*)(?:\.\d+)?$/.test(value) || (value.split('.')[1]?.length ?? 0) > decimals)
    throw new Error(`Enter a positive amount with at most ${decimals} decimal places.`);
  const amount = parseUnits(value, decimals);
  if (amount <= 0n || amount >= (1n << 127n)) throw new Error('Enter an amount greater than zero and within the pool’s range.');
  return amount;
}
export function units(value: bigint, decimals = 18, places = 6): string {
  const full = formatUnits(value, decimals);
  const [whole, part = ''] = full.split('.');
  if (value > 0n && Number(full) < 10 ** -places) return `< ${10 ** -places}`;
  return `${BigInt(whole).toLocaleString('en-US')}${part.slice(0, places).replace(/0+$/, '') ? `.${part.slice(0, places).replace(/0+$/, '')}` : ''}`;
}
export function sqrt(value: bigint): bigint {
  if (value < 0n) throw new Error('Negative square root');
  if (value < 2n) return value;
  let x = value, y = (x + 1n) / 2n;
  while (y < x) { x = y; y = (x + value / x) / 2n; }
  return x;
}
export function priceLimit(price: bigint, bps: number, buy: boolean): bigint {
  if (!Number.isInteger(bps) || bps < 10 || bps > 500) throw new Error('Price tolerance must be between 0.1% and 5%.');
  const limit = sqrt(price * price * BigInt(buy ? 10000 - bps : 10000 + bps) / 10000n);
  if (limit <= 4295128739n || limit >= 1461446703485210103287273052203988822378723970342n) throw new Error('Price limit is outside the pool range.');
  return limit;
}
export function unpackDelta(value: bigint) {
  return [BigInt.asIntN(128, value >> 128n), BigInt.asIntN(128, value)] as const;
}
export function errorText(error: unknown): string {
  const e = error as { code?: number; shortMessage?: string; message?: string; cause?: unknown };
  if (e?.code === 4001 || /rejected|denied/i.test(e?.message ?? '')) return 'Request declined in your wallet. You can try again.';
  const message = e?.shortMessage || e?.message || 'The request could not be completed.';
  if (/NothingToDonate/.test(message)) return 'No fees are ready to donate. Refresh the pool state.';
  if (/NoLiquidity/.test(message)) return 'No liquidity is in range. Accrued fees will wait in the hook.';
  if (/PartialFill/.test(message)) return 'The price limit prevents a full buy. Try a smaller amount or review the price tolerance.';
  if (/SwapTooSmall/.test(message)) return 'This swap is too small after the ETH fee. Increase the amount.';
  return message.slice(0, 480);
}
