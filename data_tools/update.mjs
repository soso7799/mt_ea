// FTMO 商品歷史資料：下載 / 增量更新 / 轉換多週期 / 產生總表
//
// 資料來源：Dukascopy 公開歷史資料（dukascopy-node），BID 價
// 時間：轉成 FTMO 伺服器時間（紐約時間 + 7 小時，冬令 UTC+2 / 夏令 UTC+3），與 MT5 圖表一致
//
// 基礎資料：
//   M1 —— 從第一次執行往回 config.m1_days 天開始，之後只往後累積
//   H1 —— 商品上市以來全部
// 其餘週期由基礎資料合成：
//   M1 → M2 M3 M4 M5 M6 M10 M12 M15 M20 M30
//   H1 → H2 H3 H4 H6 H8 H12 D1 W1 MN1
//
// 用法：node update.mjs [--data ../market_data] [--only EURUSD,XAUUSD] [--budget 300]
//   --budget  下載時間預算（分鐘），用完就停並存檔，下次接著補
//   FAKE=1    不連網，用假資料測試流程

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const args = Object.fromEntries(process.argv.slice(2).reduce((a, v, i, arr) => {
  if (v.startsWith('--')) a.push([v.slice(2), arr[i + 1] && !arr[i + 1].startsWith('--') ? arr[i + 1] : 'true']);
  return a;
}, []));

const CONFIG = JSON.parse(fs.readFileSync(path.join(HERE, 'config.json'), 'utf8'));
const DATA = path.resolve(args.data || path.join(HERE, '..', 'market_data'));
const BUDGET_MS = Number(args.budget || CONFIG.budget_minutes) * 60_000;
const ONLY = args.only ? new Set(args.only.split(',')) : null;
const FAKE = process.env.FAKE === '1';
const T0 = Date.now();

const MIN = 60_000, HOUR = 60 * MIN, DAY = 24 * HOUR;
const M1_TFS = { M1: 1, M2: 2, M3: 3, M4: 4, M5: 5, M6: 6, M10: 10, M12: 12, M15: 15, M20: 20, M30: 30 };
const H1_TFS = { H1: 1, H2: 2, H3: 3, H4: 4, H6: 6, H8: 8, H12: 12, D1: 24, W1: 'W', MN1: 'M' };
const TF_ORDER = [...Object.keys(M1_TFS), ...Object.keys(H1_TFS)];

//---------------------------------------------------------------------
// 伺服器時間 = 紐約時間 + 7h  →  美國夏令期間 UTC+3，其餘 UTC+2
//---------------------------------------------------------------------
const dstCache = new Map();
function nthSunday(y, m, n) {             // 該月第 n 個星期日（UTC 日期 ms）
  const first = Date.UTC(y, m, 1);
  const dow = new Date(first).getUTCDay();
  return first + (((7 - dow) % 7) + (n - 1) * 7) * DAY;
}
function lastSunday(y, m) {
  const last = Date.UTC(y, m + 1, 0);
  return last - new Date(last).getUTCDay() * DAY;
}
function usDst(y) {
  if (!dstCache.has(y)) {
    // 2007 起：3 月第 2 個週日 ~ 11 月第 1 個週日；之前：4 月第 1 個週日 ~ 10 月最後週日（當地 02:00）
    const start = y >= 2007 ? nthSunday(y, 2, 2) : nthSunday(y, 3, 1);
    const end = y >= 2007 ? nthSunday(y, 10, 1) : lastSunday(y, 9);
    dstCache.set(y, [start + 7 * HOUR, end + 6 * HOUR]);   // 02:00 EST = 07:00 UTC；02:00 EDT = 06:00 UTC
  }
  return dstCache.get(y);
}
function toServer(utc) {
  const [s, e] = usDst(new Date(utc).getUTCFullYear());
  return utc + ((utc >= s && utc < e) ? 3 : 2) * HOUR;
}

//---------------------------------------------------------------------
// CSV（MT5「匯入K棒」可直接讀）：<DATE>,<TIME>,<OPEN>,<HIGH>,<LOW>,<CLOSE>,<TICKVOL>
//---------------------------------------------------------------------
const HEADER = '<DATE>,<TIME>,<OPEN>,<HIGH>,<LOW>,<CLOSE>,<TICKVOL>\n';
const p2 = n => (n < 10 ? '0' : '') + n;
function fmtTime(t) {
  const d = new Date(t);
  return `${d.getUTCFullYear()}.${p2(d.getUTCMonth() + 1)}.${p2(d.getUTCDate())},${p2(d.getUTCHours())}:${p2(d.getUTCMinutes())}`;
}
function parseTime(date, time) {
  return Date.UTC(+date.slice(0, 4), +date.slice(5, 7) - 1, +date.slice(8, 10), +time.slice(0, 2), +time.slice(3, 5));
}
const num = x => String(Number(x.toPrecision(10)));
const line = b => `${fmtTime(b[0])},${num(b[1])},${num(b[2])},${num(b[3])},${num(b[4])},${Math.round(b[5])}\n`;

function readBars(file) {
  if (!fs.existsSync(file)) return [];
  const out = [];
  for (const l of fs.readFileSync(file, 'utf8').split('\n')) {
    if (!l || l[0] === '<') continue;
    const c = l.split(',');
    out.push([parseTime(c[0], c[1]), +c[2], +c[3], +c[4], +c[5], +c[6]]);
  }
  return out;
}
function lastBarTime(file) {
  if (!fs.existsSync(file)) return 0;
  const st = fs.statSync(file);
  const fd = fs.openSync(file, 'r');
  const len = Math.min(st.size, 512);
  const buf = Buffer.alloc(len);
  fs.readSync(fd, buf, 0, len, st.size - len);
  fs.closeSync(fd);
  const ls = buf.toString('utf8').trim().split('\n');
  const c = ls[ls.length - 1].split(',');
  return c[0][0] === '<' ? 0 : parseTime(c[0], c[1]);
}
function writeBars(file, bars) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const parts = [HEADER];
  for (const b of bars) parts.push(line(b));
  fs.writeFileSync(file, parts.join(''));
}
function appendBars(file, bars) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  if (!fs.existsSync(file)) fs.writeFileSync(file, HEADER);
  fs.appendFileSync(file, bars.map(line).join(''));
}

//---------------------------------------------------------------------
// 下載
//---------------------------------------------------------------------
let getHistoricalRates = null, META = {};
if (!FAKE) {
  const dk = await import('dukascopy-node');
  getHistoricalRates = dk.getHistoricalRates;
  META = dk.instrumentMetaData;
}

async function fetchRange(id, tf, from, to) {
  if (FAKE) {                                   // 假資料：隨機漫步，週末休市
    const step = tf === 'm1' ? MIN : HOUR, out = [];
    let px = 1 + (id.length % 7) / 10;
    for (let t = Math.ceil(from / step) * step; t < to; t += step) {
      const dow = new Date(t).getUTCDay();
      if (dow === 6 || (dow === 0 && new Date(t).getUTCHours() < 21)) continue;
      const o = px; px *= 1 + (Math.sin(t / 7e6) + Math.cos(t / 3e5)) * 1e-4;
      out.push([t, o, Math.max(o, px) * 1.0001, Math.min(o, px) * 0.9999, px, 100]);
    }
    return out;
  }
  for (let attempt = 1; ; attempt++) {
    try {
      const rows = await getHistoricalRates({
        instrument: id, dates: { from: new Date(from), to: new Date(to) }, timeframe: tf,
        priceType: 'bid', volumes: true, volumeUnits: 'units', ignoreFlats: true, format: 'array',
        batchSize: CONFIG.batch_size, pauseBetweenBatchesMs: CONFIG.pause_ms,
        retryCount: 3, pauseBetweenRetriesMs: 1000, failAfterRetryCount: true,
      });
      return rows.map(r => [r[0], r[1], r[2], r[3], r[4], r[5] || 0]);
    } catch (e) {
      if (attempt >= 3) throw e;
      await new Promise(r => setTimeout(r, 5000 * attempt));
    }
  }
}

function instrumentStart(id, tf) {
  const m = META[id];
  if (!m) return Date.UTC(2003, 4, 1);
  const s = tf === 'm1' ? m.startDayForMinuteCandles : m.startMonthForHourlyCandles;
  return Math.max(Date.parse(s), Date.UTC(2000, 0, 1));
}

// 把一個商品的一種基礎週期補到最新；回傳 'done' / 'budget'
async function updateBase(sym, id, tf, state) {
  const step = tf === 'm1' ? MIN : HOUR;
  const tfName = tf === 'm1' ? 'M1' : 'H1';
  const file = path.join(DATA, tfName, `${sym}.csv`);
  const st = state[sym] ||= {};
  const now = Date.now();
  const to = Math.floor(now / step) * step;           // 只要已收完的K棒

  // 從上次檢查到的位置接著下載（UTC）；沒有狀態就從頭建立
  let from = st[tfName + '_checked_utc'] || 0;
  if (!from) {
    from = instrumentStart(id, tf);
    if (tf === 'm1') from = Math.max(from, Math.floor((now - CONFIG.m1_days * DAY) / DAY) * DAY);
    if (fs.existsSync(file)) fs.rmSync(file);
  }
  const chunk = tf === 'm1' ? CONFIG.m1_chunk_days * DAY : CONFIG.h1_chunk_days * DAY;

  while (from < to) {
    if (Date.now() - T0 > BUDGET_MS) return 'budget';
    const end = Math.min(from + chunk, to);
    const lastUtc = st[tfName + '_last_utc'] || 0;
    const rows = (await fetchRange(id, tf, from, end)).filter(r => r[0] >= from && r[0] < end && r[0] > lastUtc);
    // 已上市的商品整段（>= 4 天）都沒資料，多半是網路/來源問題：不前進，回報錯誤，下次重試
    if (!rows.length && lastUtc && end - from >= 4 * DAY && now - end > 3 * DAY)
      throw new Error(`${tfName} ${fmtUtc(from)}~${fmtUtc(end)} 沒有資料（來源或網路問題？）`);
    if (rows.length) {
      // 轉伺服器時間；美國秋季回撥那一小時（週日，只有加密貨幣有）會重複，保留第一次
      let prev = lastBarTime(file);
      const srv = [];
      for (const r of rows) { const t = toServer(r[0]); if (t > prev) { srv.push([t, r[1], r[2], r[3], r[4], r[5]]); prev = t; } }
      if (srv.length) appendBars(file, srv);
      st[tfName + '_last_utc'] = rows[rows.length - 1][0];
      st[tfName + '_first_utc'] ||= rows[0][0];
    }
    // 最近 3 天的資料來源可能尚未完整發布：只記到最後一根，下次重抓尾端
    st[tfName + '_checked_utc'] = (now - end < 3 * DAY && st[tfName + '_last_utc'])
      ? Math.min(end, st[tfName + '_last_utc'] + step) : end;
    from = end;
    saveState(state);
  }
  if (!st[tfName + '_last_utc']) {                       // 整段都沒拿到資料：視為失敗，下次從頭重試
    delete st[tfName + '_checked_utc'];
    saveState(state);
    throw new Error(`${tfName} 完全沒有下載到資料（來源或網路問題？）`);
  }
  st[tfName + '_complete'] = true;
  return 'done';
}

//---------------------------------------------------------------------
// 合成其他週期（全部在伺服器時間上對齊）
//---------------------------------------------------------------------
function bucketFn(spec, baseIsHour) {
  if (spec === 'W') return t => { const d = Math.floor(t / DAY) * DAY; return d - new Date(d).getUTCDay() * DAY; }; // MT5 週K從週日開始
  if (spec === 'M') return t => { const d = new Date(t); return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1); };
  const p = spec * (baseIsHour ? HOUR : MIN);
  return t => Math.floor(t / p) * p;
}
function aggregate(bars, bucket) {
  const out = [];
  let cur = null;
  for (const b of bars) {
    const k = bucket(b[0]);
    if (!cur || cur[0] !== k) { if (cur) out.push(cur); cur = [k, b[1], b[2], b[3], b[4], b[5]]; }
    else { if (b[2] > cur[2]) cur[2] = b[2]; if (b[3] < cur[3]) cur[3] = b[3]; cur[4] = b[4]; cur[5] += b[5]; }
  }
  if (cur) out.push(cur);
  return out;
}
function buildDerived(sym) {
  const res = {};
  for (const [base, tfs, isHour] of [['M1', M1_TFS, false], ['H1', H1_TFS, true]]) {
    const bars = readBars(path.join(DATA, base, `${sym}.csv`));
    for (const [tf, spec] of Object.entries(tfs)) {
      const out = tf === base ? bars : aggregate(bars, bucketFn(spec, isHour));
      if (tf !== base && out.length) writeBars(path.join(DATA, tf, `${sym}.csv`), out);
      res[tf] = out.length ? { rows: out.length, first: out[0][0], last: out[out.length - 1][0] } : { rows: 0 };
    }
  }
  return res;
}

//---------------------------------------------------------------------
// 狀態 / 總表
//---------------------------------------------------------------------
const STATE_FILE = path.join(DATA, 'state.json');
function loadState() { return fs.existsSync(STATE_FILE) ? JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')) : {}; }
function saveState(s) { fs.mkdirSync(DATA, { recursive: true }); fs.writeFileSync(STATE_FILE, JSON.stringify(s, null, 1)); }

function loadSymbols() {
  return fs.readFileSync(path.join(HERE, 'symbols.csv'), 'utf8').split('\n')
    .map(l => l.trim()).filter(l => l && !l.startsWith('#') && !l.startsWith('symbol,'))
    .map(l => { const [symbol, id, group] = l.split(','); return { symbol, id, group }; });
}

const fmtUtc = t => t ? new Date(t).toISOString().slice(0, 16).replace('T', ' ') : '';

function writeSummary(symbols, state, stats, runInfo) {
  const updated = new Date().toISOString().slice(0, 16).replace('T', ' ') + ' UTC';
  // 長表：每商品每週期一列
  const inv = ['symbol,group,source_id,timeframe,first_bar_server,last_bar_server,rows,status,updated_utc'];
  for (const s of symbols) {
    const st = state[s.symbol] || {};
    for (const tf of TF_ORDER) {
      const x = stats[s.symbol]?.[tf] || { rows: 0 };
      const base = M1_TFS[tf] ? 'M1' : 'H1';
      const status = st.error ? 'error' : (st[base + '_complete'] ? 'ok' : (x.rows ? 'partial' : 'pending'));
      inv.push([s.symbol, s.group, s.id, tf, fmtUtc(x.first), fmtUtc(x.last), x.rows, status, st.updated || ''].join(','));
    }
  }
  fs.writeFileSync(path.join(HERE, 'inventory.csv'), inv.join('\n') + '\n');

  // 總表 Markdown：每商品一列
  const md = [];
  md.push('# 歷史資料總表', '');
  md.push(`最後執行：**${updated}**　｜　${runInfo}`, '');
  md.push('- 時間為 FTMO 伺服器時間（冬令 UTC+2、夏令 UTC+3）；價格為 Dukascopy BID，與 FTMO 報價會有小差異。');
  md.push(`- 週期：${TF_ORDER.join(' ')}。M1~M30 由 M1 合成，H1~MN1 由 H1 合成。`);
  md.push('- 資料檔在 GitHub Releases 的 `market-data`（每個週期一個 zip），每 10 天自動更新。');
  md.push('- 每商品每週期的筆數見 [`inventory.csv`](inventory.csv)。', '');
  md.push('| 商品 | 分組 | M1~M30 起 | M1~M30 至 | M1 筆數 | H1~MN1 起 | H1~MN1 至 | H1 筆數 | D1 筆數 | 狀態 | 更新時間 (UTC) |');
  md.push('|---|---|---|---|--:|---|---|--:|--:|---|---|');
  let ok = 0;
  for (const s of symbols) {
    const st = state[s.symbol] || {}, x = stats[s.symbol] || {};
    const m1 = x.M1 || {}, h1 = x.H1 || {}, d1 = x.D1 || {};
    const status = st.error ? `❌ ${st.error.slice(0, 40)}` : (st.M1_complete && st.H1_complete ? '✅' : (m1.rows || h1.rows ? '⏳ 補資料中' : '⏳ 等待'));
    if (status === '✅') ok++;
    md.push(`| ${s.symbol} | ${s.group} | ${fmtUtc(m1.first)} | ${fmtUtc(m1.last)} | ${m1.rows || 0} | ${fmtUtc(h1.first)} | ${fmtUtc(h1.last)} | ${h1.rows || 0} | ${d1.rows || 0} | ${status} | ${st.updated || ''} |`);
  }
  md.splice(4, 0, `完成 **${ok} / ${symbols.length}** 個商品`, '');
  fs.writeFileSync(path.join(HERE, 'DATA_SUMMARY.md'), md.join('\n') + '\n');
}

//---------------------------------------------------------------------
async function main() {
  const symbols = loadSymbols().filter(s => !ONLY || ONLY.has(s.symbol));
  const state = loadState();
  let stopped = false, fetched = 0;

  for (const s of symbols) {
    if (stopped) break;
    if (!FAKE && !META[s.id]) { (state[s.symbol] ||= {}).error = `unknown source_id ${s.id}`; continue; }
    try {
      for (const tf of ['h1', 'm1']) {
        const r = await updateBase(s.symbol, s.id, tf, state);
        if (r === 'budget') { stopped = true; break; }
      }
      delete state[s.symbol].error;
      state[s.symbol].updated = new Date().toISOString().slice(0, 16).replace('T', ' ');
      fetched++;
      console.log(`✔ ${s.symbol}  ${((Date.now() - T0) / 60000).toFixed(1)} 分`);
    } catch (e) {
      (state[s.symbol] ||= {}).error = String(e.message || e).replace(/[,|\n]/g, ' ');
      console.log(`✘ ${s.symbol}: ${state[s.symbol].error}`);
    }
    saveState(state);
  }

  console.log('合成多週期…');
  const all = loadSymbols();
  const stats = {};
  for (const s of all) stats[s.symbol] = buildDerived(s.symbol);
  const runInfo = stopped ? `本次時間用完，已更新 ${fetched} 個商品，下次接著補` : `本次更新 ${fetched} 個商品`;
  writeSummary(all, state, stats, runInfo);
  console.log(runInfo);
}

await main();
