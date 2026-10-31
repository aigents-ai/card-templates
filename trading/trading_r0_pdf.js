#!/usr/bin/env node
// trading_r0_pdf.js v1 (2026-11-01) — TradingAgents 보고서(complete_report.html)를 휴대폰용 PDF 로 바꾼다.
// 사용: node trading_r0_pdf.js <in.html> <out.pdf>   ·   node trading_r0_pdf.js --check
// 카드 렌더기(render.js)와 같은 방법으로 Hermes 컨테이너의 playwright·크로미움을 찾는다. 네트워크는 쓰지 않는다.
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { pathToFileURL } = require('url');

function loadPlaywright() {
  const data = process.env.HERMES_HOME || '/opt/data';
  const tries = ['playwright', 'playwright-core', '/opt/hermes/node_modules/playwright', '/opt/hermes/node_modules/playwright-core',
    path.join(data, 'tools/node_modules/playwright'), path.join(data, 'tools/node_modules/playwright-core'),
    '/opt/data/tools/node_modules/playwright', '/opt/data/tools/node_modules/playwright-core'];
  for (const t of tries) { try { return { pw: require(t), from: t }; } catch (e) { /* 다음 후보 */ } }
  return null;
}
function findChromium() {
  try { const p = fs.readFileSync('/etc/hermes/chromium-executable-path', 'utf8').trim(); if (p && fs.existsSync(p)) return p; } catch (e) { /* Hermes 이미지가 아님 */ }
  const roots = [process.env.PLAYWRIGHT_BROWSERS_PATH, '/opt/hermes/.playwright', path.join(os.homedir(), '.cache', 'ms-playwright')].filter(Boolean);
  const rel = ['chrome-headless-shell-linux64/chrome-headless-shell', 'chrome-linux/headless_shell', 'chrome-linux64/chrome', 'chrome-linux/chrome'];
  for (const r of roots) {
    let ds = [];
    try { ds = fs.readdirSync(r).filter(d => /^chromium/.test(d)).sort().reverse(); } catch (e) { continue; }
    for (const d of ds) for (const x of rel) { const p = path.join(r, d, x); if (fs.existsSync(p)) return p; }
  }
  for (const p of ['/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome']) if (fs.existsSync(p)) return p;
  return null;
}
async function launch(lp) {
  const args = ['--disable-dev-shm-usage'];
  try { return await lp.pw.chromium.launch({ args }); }
  catch (e) {
    const exe = findChromium();
    if (!exe) throw new Error('크로미움을 찾지 못했어요 — ' + String(e.message).split('\n')[0]);
    return await lp.pw.chromium.launch({ args, executablePath: exe });
  }
}

async function main() {
  const argv = process.argv.slice(2);
  const lp = loadPlaywright();
  if (!lp) throw new Error('playwright 모듈을 찾지 못했어요');
  const browser = await launch(lp);
  try {
    if (argv[0] === '--check') { console.log(`가능 · playwright ${lp.from} · 크로미움 ${browser.version()}`); return; }
    const [inp, out] = argv;
    if (!inp || !out) throw new Error('사용: node trading_r0_pdf.js <in.html> <out.pdf>');
    const page = await browser.newPage();
    // 보고서는 바깥 자원이 없는 한 장짜리 HTML — 혹시 모를 바깥 요청은 막는다
    await page.route('**/*', r => (r.request().url().startsWith('file:') ? r.continue() : r.abort()));
    await page.goto(pathToFileURL(path.resolve(inp)).href, { waitUntil: 'load', timeout: 60000 });
    await page.pdf({ path: out, format: 'A4', printBackground: true, margin: { top: '12mm', bottom: '12mm', left: '10mm', right: '10mm' } });
    console.log(out);
  } finally {
    await browser.close();
  }
}

const guard = setTimeout(() => { console.error('시간 초과(150초)'); process.exit(1); }, 150000);
main().then(() => { clearTimeout(guard); }).catch(e => { clearTimeout(guard); console.error(String((e && e.message) || e)); process.exit(1); });
