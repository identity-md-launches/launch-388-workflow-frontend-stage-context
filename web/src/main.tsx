import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { formatUnits, type Address } from 'viem';
import { loadConfig, type Config } from './config';
import { clients, donations, quote, snapshot, spotPrice, submit, switchChain, type Snapshot, type Quote, type DonationHistory, type Transaction } from './chain';
import { errorText, feeOn, parseAmount, units } from './math';
import './style.css';

const short = (s: string) => `${s.slice(0, 6)}…${s.slice(-4)}`;
function Arrow({ down = false }: { down?: boolean }) { return <span aria-hidden="true">{down ? '↓' : '↗'}</span>; }
function Mark() { return <svg viewBox="0 0 40 40" aria-hidden="true"><path d="M20 2 33 20 20 27 7 20Z" fill="currentColor"/><path d="m7 24 13 14 13-14-13 7Z" fill="currentColor"/></svg>; }
function App({ config }: { config: Config }) {
  const d = config.deployment, symbol = d.token.symbol;
  const [account, setAccount] = useState<Address>();
  const [walletChain, setWalletChain] = useState<number>();
  const [state, setState] = useState<Snapshot>();
  const [history, setHistory] = useState<DonationHistory>();
  const [historyError, setHistoryError] = useState('');
  const [readError, setReadError] = useState('');
  const [message, setMessage] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState('');
  const [buy, setBuy] = useState(true);
  const [amount, setAmount] = useState('');
  const [bps, setBps] = useState(100);
  const [currentQuote, setQuote] = useState<Quote>();
  const [tx, setTx] = useState<Transaction>();
  const [now, setNow] = useState(Date.now());
  const [inputError, setInputError] = useState('');
  const amountRef = useRef<HTMLInputElement>(null);
  const feedbackRef = useRef<HTMLDivElement>(null);
  const generation = useRef(0), readGeneration = useRef(0);
  const client = useMemo(() => clients(config, window.ethereum, walletChain), [config, walletChain]);
  const wrongChain = !!account && walletChain !== d.chainId;
  const locked = !!busy || !!tx?.pending;
  const ready = !!account && !wrongChain && !!state && !readError && now - state.updated < 60000 && !locked;
  const quoteFresh = !!currentQuote && now - currentQuote.time < 45000;
  const needsApproval = !buy && !!currentQuote && (state?.allowance ?? 0n) < currentQuote.amount;
  const balance = buy ? state?.nativeBalance : state?.tokenBalance;
  const balanceLow = !!currentQuote && balance !== undefined && currentQuote.amount > balance;
  useEffect(() => { if (error || tx) feedbackRef.current?.scrollIntoView({ block: 'nearest' }); }, [error, tx]);

  const refresh = useCallback(async () => {
    const id = ++readGeneration.current;
    setLoading(true);
    try {
      const next = await snapshot(client, config, account);
      if (id !== readGeneration.current) return;
      setState(next); setReadError('');
      try { const events = await donations(client, config, next.block); if (id === readGeneration.current) { setHistory(events); setHistoryError(''); } }
      catch { if (id === readGeneration.current) setHistoryError('Recent donation events could not load. Lifetime totals above are still from the contract.'); }
    } catch (e) { if (id === readGeneration.current) setReadError(errorText(e)); }
    finally { if (id === readGeneration.current) setLoading(false); }
  }, [client, config, account]);
  useEffect(() => { void refresh(); const timer = setInterval(() => void refresh(), 30000); return () => { clearInterval(timer); readGeneration.current++; }; }, [refresh]);
  useEffect(() => { const timer = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(timer); }, []);
  useEffect(() => {
    const provider = window.ethereum;
    if (!provider) return;
    const changed = () => { generation.current++; setQuote(undefined); setState(undefined); void Promise.all([provider.request({ method: 'eth_accounts' }), provider.request({ method: 'eth_chainId' })]).then(([accounts, chain]) => { setAccount(accounts[0]); setWalletChain(Number(chain)); }).catch(e => setError(errorText(e))); };
    const disconnected = () => { generation.current++; setAccount(undefined); setWalletChain(undefined); setQuote(undefined); setState(undefined); };
    changed(); provider.on?.('accountsChanged', changed); provider.on?.('chainChanged', changed); provider.on?.('disconnect', disconnected);
    return () => { provider.removeListener?.('accountsChanged', changed); provider.removeListener?.('chainChanged', changed); provider.removeListener?.('disconnect', disconnected); };
  }, []);
  useEffect(() => {
    if (!tx?.pending) return;
    let active = true;
    const check = async () => {
      try {
        const receipt = await client.getTransactionReceipt({ hash: tx.hash });
        if (!active) return;
        setTx({ ...tx, pending: false, failed: receipt.status === 'reverted' });
        setQuote(undefined);
        if (receipt.status === 'reverted') setError('The transaction reverted. No action completed; gas may have been spent. Refresh and review before retrying.');
        else setMessage(`${tx.action} confirmed at block ${receipt.blockNumber.toLocaleString()}.`);
        void refresh();
      } catch { /* Keep the submitted hash and block duplicate actions until a receipt is available. */ }
    };
    void check(); const timer = setInterval(() => void check(), 4000);
    return () => { active = false; clearInterval(timer); };
  }, [tx, client, refresh]);
  const reset = () => { generation.current++; setQuote(undefined); setInputError(''); setError(''); };
  async function connect() {
    setError('');
    if (!window.ethereum) { setError('No browser wallet found. Open this page in an Ethereum wallet browser, or install a browser wallet and reload.'); return; }
    setBusy('Connecting wallet…');
    try { const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' }); setAccount(accounts[0]); setWalletChain(Number(await window.ethereum.request({ method: 'eth_chainId' }))); setMessage('Wallet connected.'); }
    catch (e) { setError(errorText(e)); } finally { setBusy(''); }
  }
  async function changeChain() {
    if (!window.ethereum) return;
    setBusy('Switching network…'); setError('');
    try { await switchChain(window.ethereum, config); setWalletChain(Number(await window.ethereum.request({ method: 'eth_chainId' }))); reset(); }
    catch (e) { setError(errorText(e)); } finally { setBusy(''); }
  }
  async function getQuote(event: React.FormEvent) {
    event.preventDefault(); reset();
    let parsed;
    try { parsed = parseAmount(amount, buy ? d.network.nativeCurrency.decimals : state?.decimals ?? d.token.decimals); if (buy && feeOn(parsed) >= parsed) throw Error('This amount is too small after the ETH fee.'); }
    catch (e) { setInputError(errorText(e)); amountRef.current?.focus(); return; }
    const id = generation.current;
    setBusy('Getting quote…');
    try { const result = await quote(client, config, parsed, buy, bps); if (id === generation.current) { setQuote(result); setMessage('Quote ready. Review the fee and price limit before swapping.'); } }
    catch (e) { if (id === generation.current) setError(errorText(e)); } finally { setBusy(''); }
  }
  async function transact(action: 'donate' | 'approve' | 'swap') {
    if (!ready || !account || !window.ethereum) return;
    setBusy('Simulating transaction…'); setError(''); setMessage('Simulation first, then confirmation in your wallet.');
    try {
      const hash = await submit(config, client, window.ethereum, account, action, action === 'donate' ? undefined : currentQuote);
      setTx({ hash, action: action === 'donate' ? 'Donation' : action === 'approve' ? 'Token approval' : 'Swap', pending: true });
      setMessage('Transaction submitted. Waiting for confirmation…');
    } catch (e) { setError(errorText(e)); setMessage(''); }
    finally { setBusy(''); }
  }
  const contractLinks = [...d.contracts.map(c => ({ name: c.name, address: c.address })), { name: 'PoolSwapTest', address: d.poolSwapTest }, ...Object.entries(d.network.uniswapV4).map(([name, address]) => ({ name, address }))];
  return <>
    <a href="#main" className="skip">Skip to content</a>
    <header className="header shell">
      <a className="brand" href="#main" aria-label="ETH Fee home"><Mark/><span>ETH<span className="brand-light"> / FEE</span></span></a>
      <div className="wallet-group"><span className="badge">{d.network.name} <span>testnet</span></span><button className="button small" onClick={connect} disabled={locked || !!account}>{account ? short(account) : 'Connect wallet'} {!account && <Arrow/>}</button></div>
    </header>
    <main id="main" className="shell">
      <section className="intro">
        <div><p className="eyebrow">ETH / {symbol} · UNISWAP V4</p><h1>A little fee.<br/><span>Back to the pool.</span></h1><p className="intro-copy">Every swap collects a 0.5% fee in ETH.<br className="desktop-break"/> Anyone can return it to the pool’s liquidity providers.</p></div>
        <div className="cycle" aria-hidden="true"><span className="cycle-top">SWAP</span><span className="cycle-left">↘</span><span className="cycle-center">0.5<span>%</span><small>IN ETH</small></span><span className="cycle-right">↙</span><span className="cycle-bottom">COLLECT <span>→</span> GIVE BACK</span></div>
      </section>
      <div className="state-line"><span><span className={`dot ${state && !readError ? 'live' : ''}`}/>{readError ? 'Pool reads unavailable' : state ? `Pool state · block ${state.block.toLocaleString()}` : 'Connecting to the pool…'}{state && now - state.updated >= 60000 ? ' · stale' : ''}</span><button className="text-button" disabled={loading} onClick={() => void refresh()}>{loading ? 'Refreshing…' : 'Refresh state'} <span aria-hidden="true">↻</span></button></div>
      {readError && <div className="notice error" role="alert">{readError} Use Refresh state to retry. Actions stay disabled until verification succeeds.</div>}
      {wrongChain && <div className="notice network"><div><strong>Switch to {d.network.name}</strong><p>Your wallet is on another network. This pool uses test ETH.</p></div><button className="button" disabled={locked} onClick={changeChain}>Switch to {d.network.name}</button></div>}
      <section className="metrics" aria-label="ETH fee totals" aria-busy={loading}>
        <article className="metric accrued"><p>Ready to donate <span className="metric-index">01</span></p><h2 title={state && `${formatUnits(state.accrued, 18)} ETH`}>{state ? units(state.accrued) : '—'} <span>ETH</span></h2><p className="caption">Accrued fees waiting in the hook</p></article>
        <article className="metric"><p>Total collected <span className="metric-index">02</span></p><h2 title={state && `${formatUnits(state.collected, 18)} ETH`}>{state ? units(state.collected) : '—'} <span>ETH</span></h2><p className="caption">Lifetime ETH fees from this pool</p></article>
        <article className="metric"><p>Donated to LPs <span className="metric-index">03</span></p><h2 title={state && `${formatUnits(state.donated, 18)} ETH`}>{state ? units(state.donated) : '—'} <span>ETH</span></h2><p className="caption">Lifetime fees returned to liquidity</p></article>
      </section>
      <div className="workspace">
        <section className="donation-panel" aria-labelledby="donate-heading">
          <p className="eyebrow">A SMALL ACTION. A SHARED POOL.</p><h2 id="donate-heading">Put the fees <br/>back to work.</h2>
          <p>Donate all accrued ETH to liquidity providers currently in range. The ETH comes from collected swap fees; you only pay network gas.</p>
          <div className="donation-flow" aria-label="Swap fees go to the hook, then to liquidity providers"><span>Swap fees</span><Arrow/><span>Hook</span><Arrow/><span>LPs</span></div>
          <button className="button donate" disabled={!ready || !state?.accrued || !state?.liquidity} onClick={() => void transact('donate')}>Donate accrued ETH <Arrow/></button>
          <p className="caption">{!account ? 'Connect a wallet to donate.' : wrongChain ? `Switch to ${d.network.name} to donate.` : !state ? 'Waiting for verified pool state.' : state.accrued === 0n ? 'No fees are ready yet. They accrue as people swap.' : state.liquidity === 0n ? 'No liquidity is in range. Fees will wait until it returns.' : 'Permissionless. No personal ETH donation required.'}</p>
          <div className="mini-facts"><span>Fixed fee<strong>0.5% in ETH</strong></span><span>Destination<strong>In-range LPs</strong></span></div>
        </section>
        <section className="swap-panel" aria-labelledby="swap-heading">
          <div className="section-title"><h2 id="swap-heading">Make a swap</h2><span className="quiet-badge">Exact input</span></div>
          <div className="segmented" aria-label="Swap direction"><button type="button" aria-pressed={buy} disabled={locked} onClick={() => { setBuy(true); setAmount(''); reset(); }}>Buy {symbol}</button><button type="button" aria-pressed={!buy} disabled={locked} onClick={() => { setBuy(false); setAmount(''); reset(); }}>Sell {symbol}</button></div>
          <form onSubmit={getQuote} noValidate>
            <div className={`amount-box ${inputError ? 'invalid' : ''}`}><label htmlFor="amount">You pay {buy ? '' : 'up to'}</label><div className="amount-row"><input id="amount" name="amount" ref={amountRef} value={amount} onChange={e => { setAmount(e.target.value); reset(); }} disabled={locked} placeholder="0.00" inputMode="decimal" autoComplete="off" aria-invalid={!!inputError} aria-describedby="amount-hint amount-error"/><span className="currency">{buy ? <Mark/> : <span className="token-icon">F</span>}{buy ? 'ETH' : symbol}</span></div><p id="amount-hint" className="caption">{balance !== undefined ? `Balance: ${units(balance, buy ? 18 : state?.decimals)} ${buy ? 'ETH' : symbol}` : 'Connect a wallet to see your balance'}</p></div>
            <p id="amount-error" className="field-error">{inputError}</p>
            <div className="swap-arrow" aria-hidden="true">↓</div>
            <div className="amount-box output"><span className="field-label">Estimated receive</span><div className="amount-row"><output className="output-number">{currentQuote ? units(currentQuote.output, buy ? state?.decimals : 18) : '—'}</output><span className="currency">{buy ? <span className="token-icon">F</span> : <Mark/>}{buy ? symbol : 'ETH'}</span></div><p className="caption">{currentQuote ? quoteFresh ? 'Quote includes the hook and pool fees' : 'Quote expired. Refresh before continuing.' : 'Get a quote to see the expected output'}</p></div>
            <div className="tolerance"><label htmlFor="tolerance">Price tolerance</label><select id="tolerance" value={bps} disabled={locked} onChange={e => { setBps(Number(e.target.value)); reset(); }}><option value={50}>0.5%</option><option value={100}>1.0%</option><option value={300}>3.0%</option><option value={500}>5.0%</option></select></div>
            <dl className="quote-details"><div><dt>Hook fee · 0.5%</dt><dd title={currentQuote && `${formatUnits(currentQuote.fee, 18)} ETH`}>{currentQuote ? `${!buy ? '≈ ' : ''}${units(currentQuote.fee, 18, 8)} ETH` : '—'}</dd></div><div><dt>Pool fee</dt><dd>{d.pool.fee / 10000}%</dd></div><div><dt>Network gas</dt><dd>Additional · shown in wallet</dd></div></dl>
            <button className="button quote-button" type="submit" disabled={locked || wrongChain || !state || !!readError || state.sqrtPriceX96 === 0n}>{currentQuote ? 'Refresh quote' : 'Get quote'} <Arrow/></button>
          </form>
          {!account ? <button className="button primary" disabled={locked} onClick={connect}>Connect wallet to swap <Arrow/></button> : <button className="button primary" disabled={!ready || !quoteFresh || balanceLow} onClick={() => void transact(needsApproval ? 'approve' : 'swap')}>{needsApproval ? `Approve ${symbol} for this amount` : `Swap ${buy ? 'ETH' : symbol} for ${buy ? symbol : 'ETH'}`} <Arrow/></button>}
          {balanceLow && <p className="field-error">Insufficient {buy ? 'ETH' : symbol} balance. Reduce the amount.</p>}
          {!buy && <p className="caption">Selling needs a separate {symbol} approval to PoolSwapTest. Only the entered amount is approved. Get a new quote after approval.</p>}
          <p className="caption protection-note">Pool price limit only. No guaranteed minimum output or transaction deadline.</p>
          <details className="swap-notes"><summary>How price protection works</summary><p>PoolSwapTest enforces a pool price limit based on your tolerance. The quote is an estimate, not a guaranteed amount.</p><p>Every swap is simulated before signing. Buys must fill completely or revert. Sells may partially fill at the price limit; unspent {symbol} stays in your wallet. The sell fee preview can differ by one wei because the quote reports ETH after the rounded fee. Quotes expire here after 45 seconds; a pending transaction has no onchain expiry.</p></details>
          <p className="testnet-note">{d.network.name} testnet only · Test tokens have no monetary value</p>
        </section>
      </div>
      <div className="feedback" ref={feedbackRef} aria-label="Wallet and transaction status"><p role="status">{busy || message}</p>{error && <p role="alert" className="notice error">{error}</p>}{tx && <p className="transaction"><span>{tx.pending ? 'Pending' : tx.failed ? 'Reverted' : 'Confirmed'} · {tx.action}</span><a href={`${d.network.explorer}/tx/${tx.hash}`} target="_blank" rel="noreferrer">View transaction <Arrow/></a></p>}</div>
      <section className="activity" aria-labelledby="activity-heading"><div className="section-title"><h2 id="activity-heading">Returned to the pool</h2><span className="caption">Recent donations</span></div>{historyError ? <p>{historyError}</p> : !history ? <p className="empty-state">Loading donation events…</p> : !history.rows.length ? <p className="empty-state">No donations in the latest {Number((state?.block ?? history.fromBlock) - history.fromBlock + 1n).toLocaleString()} blocks. Lifetime donations are shown above.</p> : <ul className="event-list">{history.rows.map(row => <li key={row.hash}><span className="event-icon" aria-hidden="true">↗</span><span>Fees donated<small>Block {row.block.toLocaleString()}</small></span><strong>{units(row.amount)} ETH</strong><a href={`${d.network.explorer}/tx/${row.hash}`} target="_blank" rel="noreferrer" aria-label={`Donation transaction ${row.hash}`}>View <Arrow/></a></li>)}</ul>}</section>
      <section className="pool-details"><div><h2>One pool. Fully onchain.</h2><p>{state && state.sqrtPriceX96 > 0n ? `1 ETH ≈ ${spotPrice(state)} ${symbol} · Spot price from StateView` : 'Pool price will appear when live state is available.'}</p></div><details><summary>Pool & contract details</summary><dl><div><dt>Pool ID</dt><dd className="address">{config.poolId}</dd></div><div><dt>Tick spacing</dt><dd>{d.pool.tickSpacing}</dd></div><div><dt>Connected wallet</dt><dd className="address">{account ?? 'Not connected'}</dd></div>{contractLinks.map(c => <div key={c.name}><dt>{c.name}</dt><dd><a className="address" href={`${d.network.explorer}/address/${c.address}`} target="_blank" rel="noreferrer">{c.address} <Arrow/></a></dd></div>)}<div><dt>Deployed source</dt><dd className="address">{d.sourceCommit}</dd></div></dl><p className="caption">hookData is empty and ignored by this hook. Fee events identify the router, not the trader. ABI hashes are checked on load; chain and contract code are checked before enabling transactions.</p></details></section>
    </main>
    <footer className="shell footer"><span>ETH / FEE <span className="footer-dot">·</span> A little back, every swap.</span><div><a href="./imd-deployment.json">Deployment manifest <Arrow/></a><a href={d.network.faucets[0]} target="_blank" rel="noreferrer">Get test ETH <Arrow/></a></div></footer>
  </>;
}
function Boot() {
  const [config, setConfig] = useState<Config>(); const [error, setError] = useState('');
  useEffect(() => { void loadConfig().then(setConfig).catch(e => setError(errorText(e))); }, []);
  if (error) return <main className="boot shell"><h1>Deployment unavailable</h1><p role="alert">{error}</p><button className="button" onClick={() => location.reload()}>Reload deployment</button></main>;
  return config ? <App config={config}/> : <main className="boot shell"><h1>ETH / FEE</h1><p role="status">Verifying deployment and contract interfaces…</p></main>;
}
createRoot(document.getElementById('root')!).render(<Boot/>);
