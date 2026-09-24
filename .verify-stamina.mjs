import fs from 'node:fs';
const html = fs.readFileSync('index.html', 'utf8');
const code = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const els = new Map();
const makeEl = id => { if (els.has(id)) return els.get(id);
  const el = { id, value: '', textContent: '', _html: '', hidden: false, style: {}, dataset: {},
    classList: { toggle() {}, add() {}, remove() {}, contains() { return false } },
    addEventListener() {}, focus() {}, select() {}, set innerHTML(v) { this._html = v }, get innerHTML() { return this._html } };
  els.set(id, el); return el; };
const doc = { getElementById: makeEl, querySelectorAll: () => [], body: { style: {} }, activeElement: null };
const ls = { _d: {}, getItem(k) { return k in this._d ? this._d[k] : null }, setItem(k, v) { this._d[k] = v } };
const cryptoWs = { subtle: { digest: async (a, d) => { const { createHash } = await import('node:crypto'); const hex = createHash('sha256').update(Buffer.from(d)).digest('hex'); const b = new Uint8Array(hex.length / 2); for (let i = 0; i < hex.length; i += 2) b[i / 2] = parseInt(hex.substr(i, 2), 16); return b.buffer; } } };
new Function('document', 'localStorage', 'window', 'navigator', 'console', 'confirm', 'crypto', code)(
  doc, ls, { isSecureContext: false, scrollTo() {}, crypto: cryptoWs }, {}, { error() {}, log() {} }, () => true, cryptoWs);

console.log('--- 普通宝石（含体力列） ---');
console.log('表头:', makeEl('priceTableHeadRow')._html);
const rows = makeEl('gemPriceRows')._html;
const lv2 = (rows.match(/<div class="price-row"><span>2级<\/span>([\s\S]*?)<\/div>/) || [])[1] || '';
console.log('2级行含体力成本:', lv2.includes('stamina-cost'));
console.log('2级体力成本值:', (lv2.match(/stamina-cost[^>]*>([^<]+)</) || [])[1]);
const lv8 = (rows.match(/<div class="price-row"><span>8级<\/span>([\s\S]*?)<\/div>/) || [])[1] || '';
console.log('8级体力成本值:', (lv8.match(/stamina-cost[^>]*>([^<]+)</) || [])[1]);
console.log('体力列title:', (lv8.match(/title="([^"]+)"/) || [])[1]);

// 切到星辉石验证隐藏
const st = JSON.parse(ls._d.gemCalculatorSettings);
st.gemType = 'star'; ls._d.gemCalculatorSettings = JSON.stringify(st);
els.delete('priceTableHeadRow'); els.delete('gemPriceRows');
new Function('document', 'localStorage', 'window', 'navigator', 'console', 'confirm', 'crypto', code)(
  doc, ls, { isSecureContext: false, scrollTo() {}, crypto: cryptoWs }, {}, { error() {}, log() {} }, () => true, cryptoWs);
console.log('');
console.log('--- 星辉石（应无体力列） ---');
console.log('表头含体力:', makeEl('priceTableHeadRow')._html.includes('体力'), '(应为false)');
console.log('行含stamina-cost:', makeEl('gemPriceRows')._html.includes('stamina-cost'), '(应为false)');
