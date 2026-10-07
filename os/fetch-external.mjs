// os/fetch-external.mjs · download the prebuilt disks the site boots but does not build
//   npm run os:fetch
//
// each os/external/<id>.json names the official release asset ("url") and its "sha256".
// the download is cached in os/cache/ (gitignored) and copied to public/os/<image>;
// nothing is downloaded twice, and a public/os copy that was changed is restored.
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const extDir = join(root, 'os', 'external'), cache = join(root, 'os', 'cache'), out = join(root, 'public', 'os');
mkdirSync(cache, { recursive: true }); mkdirSync(out, { recursive: true });
const sha256 = file => existsSync(file) ? createHash('sha256').update(readFileSync(file)).digest('hex') : null;

for (const f of readdirSync(extDir).filter(f => f.endsWith('.json')).sort()) {
  const meta = JSON.parse(readFileSync(join(extDir, f), 'utf8'));
  const cached = join(cache, meta.url.split('/').slice(-2).join('-'));   // e.g. v0.9.2-fd1440.img
  if (sha256(cached) !== meta.sha256) {
    process.stdout.write(`${meta.id.padEnd(9)} downloading ${meta.url} ... `);
    const res = await fetch(meta.url, { redirect: 'follow' });
    if (!res.ok) throw new Error(`${meta.id}: HTTP ${res.status} for ${meta.url}`);
    const data = Buffer.from(await res.arrayBuffer());
    const got = createHash('sha256').update(data).digest('hex');
    if (got !== meta.sha256) throw new Error(`${meta.id}: sha256 ${got}, expected ${meta.sha256}`);
    writeFileSync(cached + '.part', data); renameSync(cached + '.part', cached);
    console.log(`${data.length} bytes`);
  }
  const dst = join(out, meta.image);
  if (sha256(dst) !== meta.sha256) copyFileSync(cached, dst);
  console.log(`${meta.id.padEnd(9)} ${meta.image.padEnd(14)} ${String(meta.size).padStart(8)} bytes · ${meta.source}`);
}
