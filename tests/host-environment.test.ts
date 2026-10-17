import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { build } from 'vite';

test('production renderer retains Electron desktop variables despite Vite process.env replacement', async () => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'winboat-env-'));
    try {
        const source = path.resolve('src/renderer/lib/host-environment.ts').replaceAll('\\', '/');
        await fs.writeFile(path.join(root, 'entry.ts'), `import {hostEnvironment} from ${JSON.stringify(source)}; window.actual=hostEnvironment(); window.control=process.env.DISPLAY;`);
        const result = await build({ configFile: false, root, logLevel: 'silent', build: {
            write: false, modulePreload: { polyfill: false }, rollupOptions: { input: path.join(root, 'entry.ts') },
        }});
        assert(!Array.isArray(result) && 'output' in result);
        const output = result.output.find(item => item.type === 'chunk'); assert(output && 'code' in output);
        const env = { DISPLAY: ':77', WAYLAND_DISPLAY: 'wayland-test', XDG_RUNTIME_DIR: '/run/user/1000' };
        const window: { actual?: typeof env; control?: string } = {};
        vm.runInNewContext(output.code, { window, require: (name: string) => { assert.equal(name, 'process'); return { env }; } });
        assert.equal(window.control, undefined, 'control must reproduce the production replacement');
        assert.equal(window.actual, env);
    } finally { await fs.rm(root, { recursive: true, force: true }); }
});
