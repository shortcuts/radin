// Run through `make diagrams`, which installs the pinned pele first.
import { render } from 'pele';
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
const dir = new URL('.', import.meta.url);
for (const f of readdirSync(dir).filter((n) => n.endsWith('.mmd'))) {
  const { svg } = render(readFileSync(new URL(f, dir), 'utf8'));
  writeFileSync(new URL(f.replace('.mmd', '.svg'), dir), svg);
}
