// Renders on every request, so an edited .mmd shows after a browser refresh.
import { render } from 'pele';
import { createServer } from 'node:http';
import { readdirSync, readFileSync } from 'node:fs';

const dir = new URL('.', import.meta.url);
const port = Number(process.env.PORT) || 4173;
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');

const page = () => {
  const sections = readdirSync(dir)
    .filter((n) => n.endsWith('.mmd'))
    .map((n) => {
      try {
        const { svg } = render(readFileSync(new URL(n, dir), 'utf8'));
        return `<section><h2>${n.replace('.mmd', '')}</h2><div class="d">${svg}</div></section>`;
      } catch (e) {
        return `<section><h2>${n}</h2><pre>${esc(String(e))}</pre></section>`;
      }
    });
  return `<!doctype html><meta charset="utf-8"><title>radin lifecycle</title>
<style>
:root{--pele-bg:#fff;--pele-fg:#1c1b1a;--pele-muted:#6b6966;--pele-line:#1c1b1a;--pele-surface:#f3f1ee;--pele-surface-alt:#e7e4df;--pele-border:#c9c5be}
@media(prefers-color-scheme:dark){:root{--pele-bg:#171615;--pele-fg:#ece9e4;--pele-muted:#9a9690;--pele-line:#ece9e4;--pele-surface:#252321;--pele-surface-alt:#302d2a;--pele-border:#4a4640}}
body{margin:0;padding:24px;background:var(--pele-bg);color:var(--pele-fg);font:15px system-ui,sans-serif}
h2{font-size:13px;letter-spacing:.06em;text-transform:uppercase;color:var(--pele-muted)}
.d{overflow-x:auto;padding-bottom:24px}
</style>${sections.join('')}`;
};

createServer((req, res) => {
  res.setHeader('content-type', 'text/html; charset=utf-8');
  res.end(page());
}).listen(port, () => console.log(`http://localhost:${port}`));
