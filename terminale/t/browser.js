#!/usr/bin/env node
/* Browser test of the Terminale UI with headless Chrome.
 *   npm i puppeteer-core     (anywhere on NODE_PATH)
 *   node t/browser.js http://127.0.0.1:7681/ USER PASSWORD [screenshot-dir]
 * CHROME=/path/to/chrome overrides the browser binary. */
const puppeteer = require('puppeteer-core');
const fs = require('fs');
const path = require('path');
const [base, user, password, shots] = process.argv.slice(2);
const sleep = ms => new Promise(r => setTimeout(r, ms));
let fails = 0;
function check(ok, name) { console.log((ok ? '  PASS: ' : '  FAIL: ') + name); if (!ok) fails++; }

(async () => {
  const browser = await puppeteer.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', headless: 'new', args: ['--no-sandbox', '--window-size=1300,760'] });
  const page = await browser.newPage();
  await page.setViewport({ width: 1300, height: 760 });
  const errors = [];
  page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('dialog', d => d.accept());
  const shot = async name => { if (shots) await page.screenshot({ path: path.join(shots, name + '.png') }); };
  const tabCount = () => page.evaluate(() => document.querySelectorAll('.tab').length);
  const online = n => page.waitForFunction(k => document.querySelectorAll('.tab:not(.offline)').length === k, { timeout: 10000 }, n);
  const type = async s => { await page.keyboard.type(s); await sleep(350); };

  await page.goto(base);
  await page.type('#username', user); await page.type('#password', password);
  await Promise.all([page.waitForNavigation(), page.click('#submit')]);
  await online(1);
  await sleep(600);
  check(page.url().replace(/[?#].*/, '') === base, 'app served at ' + base);

  // files: go somewhere empty, upload through the panel, see it listed
  const work = fs.mkdtempSync('/tmp/terminale-ui-');
  await type('cd ' + work + ' && clear\n');
  await page.click('#files-btn');
  await page.waitForFunction(w => document.getElementById('files-input').value === w, { timeout: 5000 }, work);
  check(true, 'files panel opens in the terminal\'s directory');
  fs.writeFileSync(path.join(work, '..', path.basename(work) + '-src.txt'), 'uploaded through the browser\n');
  const input = await page.$('#files-pick');
  await input.uploadFile(path.join(work, '..', path.basename(work) + '-src.txt'));
  await page.waitForFunction(() => /-src\.txt/.test(document.getElementById('files-list').textContent), { timeout: 8000 });
  const up = path.join(work, path.basename(work) + '-src.txt');
  check(fs.existsSync(up) && fs.readFileSync(up, 'utf8') === 'uploaded through the browser\n', 'uploaded file arrived intact');
  await shot('files');
  await page.click('#files-close');

  // search
  await type('echo needle-one; echo haystack; echo needle-two\n');
  await page.keyboard.down('Control'); await page.keyboard.down('Shift'); await page.keyboard.press('KeyF'); await page.keyboard.up('Shift'); await page.keyboard.up('Control');
  await page.waitForFunction(() => !document.getElementById('searchbar').hidden, { timeout: 3000 });
  await page.type('#search-input', 'needle');
  await page.keyboard.press('Enter');
  await sleep(300);
  const sel = await page.evaluate(() => document.querySelector('.xterm-decoration-container, .xterm-decoration-overview-ruler') ? 1 : 0);
  check(sel === 1, 'search highlights matches');
  await shot('search');
  await page.keyboard.press('Escape');
  check(await page.evaluate(() => document.getElementById('searchbar').hidden), 'Escape closes search');

  // second tab + split
  await page.click('#new');
  await online(2);
  await sleep(500);
  await type('echo right-pane\n');
  await page.keyboard.down('Alt'); await page.keyboard.down('Shift'); await page.keyboard.press('KeyS'); await page.keyboard.up('Shift'); await page.keyboard.up('Alt');
  await sleep(500);
  const split = await page.evaluate(() => ({ on: document.getElementById('panes').classList.contains('split'), shown: document.querySelectorAll('.pane.shown').length,
    widths: Array.from(document.querySelectorAll('.pane.shown')).map(p => Math.round(p.getBoundingClientRect().width)) }));
  check(split.on && split.shown === 2 && Math.abs(split.widths[0] - split.widths[1]) < 8, 'split view shows two terminals side by side');
  await type('stty size\n');
  await shot('split');
  await page.keyboard.down('Alt'); await page.keyboard.down('Shift'); await page.keyboard.press('KeyS'); await page.keyboard.up('Shift'); await page.keyboard.up('Alt');
  await sleep(300);
  check(await page.evaluate(() => !document.getElementById('panes').classList.contains('split') && document.querySelectorAll('.pane.shown').length === 1), 'leaving split view');

  // detach, then re-attach from the sessions menu
  await type('export KEPT=detached-state\n');
  await page.keyboard.down('Alt'); await page.keyboard.down('Shift'); await page.keyboard.press('KeyD'); await page.keyboard.up('Shift'); await page.keyboard.up('Alt');
  await sleep(500);
  check(await tabCount() === 1, 'detach removes the tab');
  await page.reload();
  await online(1);
  await sleep(500);
  check(await tabCount() === 1, 'a detached session stays detached after reload');
  await page.click('#sessions-btn');
  await page.waitForSelector('#menu button.item[data-session]', { timeout: 5000 });
  const rows = await page.evaluate(() => Array.from(document.querySelectorAll('#menu button.item[data-session] small')).map(e => e.textContent));
  check(rows.length === 2 && rows.filter(r => /detached/.test(r)).length === 1 && rows.filter(r => /open here/.test(r)).length === 1, 'sessions menu lists open and detached sessions');
  await shot('sessions-menu');
  await page.evaluate(() => Array.from(document.querySelectorAll('#menu button.item[data-session]')).filter(b => /detached/.test(b.textContent))[0].click());
  await online(2);
  await sleep(700);
  await type('echo $KEPT > ' + work + '/kept.txt\n');
  check(fs.existsSync(work + '/kept.txt') && fs.readFileSync(work + '/kept.txt', 'utf8').trim() === 'detached-state', 're-attached session kept its state');

  // tab context menu + reorder
  await page.click('.tab:nth-child(1)', { button: 'right' });
  await page.waitForSelector('#menu button.item', { timeout: 3000 });
  const items = await page.evaluate(() => Array.from(document.querySelectorAll('#menu button.item .grow')).map(e => e.textContent));
  check(items.join('|') === 'Rename|Split view with this tab|Detach (keeps running)|Close (ends the shell)', 'tab menu');
  await page.keyboard.press('Escape');
  const before = await page.evaluate(() => JSON.parse(localStorage.getItem('terminale.order')));
  await page.evaluate(() => {
    const t = document.querySelectorAll('.tab'), dt = new DataTransfer();
    t[1].dispatchEvent(new DragEvent('dragstart', { bubbles: true, dataTransfer: dt }));
    t[0].dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true, dataTransfer: dt }));
    t[0].dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt }));
    t[1].dispatchEvent(new DragEvent('dragend', { bubbles: true, dataTransfer: dt }));
  });
  const after = await page.evaluate(() => JSON.parse(localStorage.getItem('terminale.order')));
  check(before.length === 2 && after[0] === before[1] && after[1] === before[0], 'dragging a tab reorders (and is remembered)');

  // touch keys: sticky Ctrl + c interrupts a running command
  await page.click('#settings-btn');
  await page.select('#set-keyBar', 'on');
  await sleep(300);
  const sec = await page.evaluate(() => document.getElementById('logins').textContent);
  check(/this browser/.test(sec) && /Two-factor sign-in is off/.test(sec) && /Recent sign-in attempts/.test(sec), 'settings show sign-ins and two-factor state');
  await shot('settings');
  await page.click('#settings-close');
  check(await page.evaluate(() => !document.getElementById('keybar').hidden), 'on-screen keys shown');
  await type('sleep 30; echo not-interrupted > ' + work + '/int.txt\n');
  await page.click('#keybar [data-mod="ctrl"]');
  await type('c');
  await type('echo after-ctrl-c > ' + work + '/int2.txt\n');
  check(!fs.existsSync(work + '/int.txt') && fs.existsSync(work + '/int2.txt'), 'on-screen Ctrl + c interrupts');
  await page.evaluate(() => document.querySelector('#keybar [data-key="up"]').click());
  await sleep(200);
  await shot('keybar');
  await page.click('#settings-btn'); await page.select('#set-keyBar', 'auto'); await sleep(600); await page.click('#settings-close');

  // many tabs: more than the browser's WebGL context limit
  for (let i = 0; i < 18; i++) { await page.click('#new'); await page.waitForFunction(k => document.querySelectorAll('.tab').length === k, { timeout: 8000 }, 3 + i); }
  await online(20);
  await sleep(800);
  const gl = await page.evaluate(() => ({ tabs: document.querySelectorAll('.tab').length, canvases: document.querySelectorAll('.pane canvas').length }));
  check(gl.tabs === 20, '20 terminals open and connected');
  await page.evaluate(() => document.querySelectorAll('.tab')[19].dispatchEvent(new MouseEvent('mousedown', { bubbles: true, button: 0 })));
  await type('echo tab-twenty > ' + work + '/t20.txt\n');
  check(fs.existsSync(work + '/t20.txt'), 'the 20th tab works');
  await shot('many-tabs');

  // clean up: end every session from the menu's API
  await page.evaluate(async () => {
    const j = await (await fetch('api/sessions')).json();
    for (const s of j.sessions) await fetch('api/sessions/' + s.id + '/kill', { method: 'POST' });
  });
  await page.waitForFunction(() => document.querySelectorAll('.tab').length === 0, { timeout: 10000 });
  check(true, 'all sessions ended; tabs closed themselves');
  check(errors.length === 0, 'no console errors' + (errors.length ? ': ' + errors.slice(0, 3).join(' | ') : ''));
  fs.rmSync(work, { recursive: true, force: true });
  fs.rmSync(work + '-src.txt', { force: true });
  await browser.close();
  console.log(fails ? fails + ' browser check(s) failed' : 'All browser checks passed!');
  process.exit(fails ? 1 : 0);
})().catch(e => { console.error('BROWSER TEST FAILED:', e.message); process.exit(1); });
