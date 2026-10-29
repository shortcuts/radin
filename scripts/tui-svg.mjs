// Run through `make screenshot`: renders a recorded TUI byte stream to a static SVG.
import pkg from '@xterm/headless';
import { readFileSync, writeFileSync } from 'node:fs';
const { Terminal } = pkg;
const [, , inFile, outFile, cols, rows] = process.argv;
const term = new Terminal({ cols: +cols, rows: +rows, allowProposedApi: true });
await new Promise((r) => term.write(readFileSync(inFile), r));
const buf = term.buffer.active;

const base = ['#000000','#cd3131','#0dbc79','#e5e510','#2472c8','#bc3fbc','#11a8cd','#e5e5e5','#666666','#f14c4c','#23d18b','#f5f543','#3b8eea','#d670d6','#29b8db','#ffffff'];
const pal = (n) => {
  if (n < 16) return base[n];
  if (n >= 232) { const v = 8 + (n - 232) * 10; return `rgb(${v},${v},${v})`; }
  n -= 16; const l = [0, 95, 135, 175, 215, 255];
  return `rgb(${l[Math.floor(n / 36)]},${l[Math.floor(n / 6) % 6]},${l[n % 6]})`;
};
const color = (c, def) => c.isDefault() ? def : c.isRGB() ? '#' + c.getColor().toString(16).padStart(6, '0') : pal(c.getColor());
const CW = 8.4, CH = 18, PAD = 16, BG = '#1e1e1e', FG = '#d4d4d4';
const W = Math.ceil(+cols * CW + PAD * 2), H = +rows * CH + PAD * 2 + 28;
let bgs = '', txt = '';
const cell = buf.getNullCell();
for (let y = 0; y < +rows; y++) {
  const line = buf.getLine(y); if (!line) continue;
  let run = null;
  const flush = () => { if (run && run.t.trim()) txt += `<text x="${PAD + run.x * CW}" y="${PAD + 28 + y * CH + 13}" fill="${run.fg}"${run.b ? ' font-weight="bold"' : ''}${run.d ? ' opacity=".6"' : ''} textLength="${run.t.length * CW}" xml:space="preserve">${run.t.replace(/&/g,'&amp;').replace(/</g,'&lt;')}</text>`; run = null; };
  for (let x = 0; x < +cols; x++) {
    line.getCell(x, cell);
    let fg = color(cell.isFgDefault() ? { isDefault: () => true } : { isDefault: () => false, isRGB: () => cell.isFgRGB(), getColor: () => cell.getFgColor() }, FG);
    let bg = cell.isBgDefault() ? null : cell.isBgRGB() ? '#' + cell.getBgColor().toString(16).padStart(6, '0') : pal(cell.getBgColor());
    if (cell.isInverse()) { const t = bg ?? BG; bg = fg; fg = t; }
    if (bg) bgs += `<rect x="${PAD + x * CW}" y="${PAD + 28 + y * CH}" width="${CW + .5}" height="${CH}" fill="${bg}"/>`;
    const ch = cell.getChars() || ' ';
    const b = !!cell.isBold(), d = !!cell.isDim();
    if (run && run.fg === fg && run.b === b && run.d === d) run.t += ch; else { flush(); run = { x, fg, b, d, t: ch }; }
  }
  flush();
}
const dots = [['#ff5f56', 0], ['#ffbd2e', 1], ['#27c93f', 2]].map(([c, i]) => `<circle cx="${PAD + 6 + i * 18}" cy="${PAD + 4}" r="5.5" fill="${c}"/>`).join('');
writeFileSync(outFile, `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" font-family="'JetBrains Mono','SF Mono',Menlo,Consolas,monospace" font-size="13.5"><rect width="${W}" height="${H}" rx="10" fill="${BG}"/>${dots}${bgs}${txt}</svg>`);
