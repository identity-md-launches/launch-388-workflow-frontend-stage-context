import { test } from 'node:test';
import assert from 'node:assert/strict';
import { feeOn, parseAmount, priceLimit, sqrt, unpackDelta, errorText } from '../src/math.ts';

test('ETH fee uses Solidity ceiling division, including dust', () => {
  assert.equal(feeOn(0n), 0n); assert.equal(feeOn(1n), 1n);
  assert.equal(feeOn(200n), 1n); assert.equal(feeOn(201n), 2n);
  assert.equal(feeOn(10n ** 18n), 5n * 10n ** 15n);
});
test('amount parser rejects silent rounding and unsupported input', () => {
  assert.equal(parseAmount('0.000000000000000001', 18), 1n);
  for (const input of ['-1', '0', '1e4', '0.0000000000000000001', 'abc', '1,000', '']) assert.throws(() => parseAmount(input, 18));
});
test('price limits move in the correct direction using integer math', () => {
  const price = 79299443975792720780679863727831n;
  assert(priceLimit(price, 100, true) < price);
  assert(priceLimit(price, 100, false) > price);
  const lower = priceLimit(price, 100, true);
  assert(lower * lower <= price * price * 9900n / 10000n);
  assert.throws(() => priceLimit(price, 10000, true));
  assert.equal(sqrt(99n), 9n);
});
test('PoolSwapTest signed delta decodes ETH input and token output', () => {
  const packed = (-(10n ** 15n) << 128n) | 2000n;
  assert.deepEqual(unpackDelta(packed), [-(10n ** 15n), 2000n]);
  const sell = (1000n << 128n) | BigInt.asUintN(128, -5000n);
  assert.deepEqual(unpackDelta(sell), [1000n, -5000n]);
});
test('rejection and hook reverts have recovery copy', () => {
  assert.match(errorText({ code: 4001 }), /declined/);
  assert.match(errorText(Error('PartialFill')), /smaller amount/);
  assert.match(errorText(Error('NoLiquidity')), /wait/);
});
