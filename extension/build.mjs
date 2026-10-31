import { build } from 'esbuild';
import { cpSync, rmSync } from 'node:fs';

rmSync('dist', { recursive: true, force: true });
cpSync('static', 'dist', { recursive: true });
await build({
  entryPoints: ['src/background.ts', 'src/app.ts'],
  outdir: 'dist',
  bundle: true,
  format: 'esm',
  target: 'chrome120',
  minify: true,
  sourcemap: false,
});
