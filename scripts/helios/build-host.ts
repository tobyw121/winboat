import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { HELIOS_IMAGE } from '../../src/shared/helios.ts';
const args = ['build', '--build-arg', `HELIOS_BUILD_JOBS=${process.env.HELIOS_BUILD_JOBS || '4'}`,
    '-f', 'helios/host/Dockerfile', '-t', HELIOS_IMAGE];
if (process.env.CODEX_PROXY_CERT) args.push('--secret', 'id=proxy_ca,src=/etc/ssl/certs/ca-certificates.crt');
args.push('.');
const buildx = process.env.BUILDX_CONFIG || path.join(process.env.XDG_CACHE_HOME || os.tmpdir(), 'winboat-buildx');
fs.mkdirSync(buildx, { recursive: true });
const result = spawnSync('docker', args, { env: { ...process.env, BUILDX_CONFIG: buildx }, cwd: fileURLToPath(new URL('../../', import.meta.url)), stdio: 'inherit' });
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
