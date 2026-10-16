const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { getMainFileMatchers, copyFiles } = require('app-builder-lib/out/fileMatcher');
const asar = require('@electron/asar');

test('the effective Electron file matchers exclude VM disks over 4 GB and private checkout data', async t => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'winboat-packaging-'));
    t.after(() => fs.rm(root, { recursive: true, force: true }));
    const app = path.join(root, 'app');
    const output = path.join(root, 'package');
    const files = {
        'package.json': '{"name":"fixture","version":"1.0.0","main":"main/main.js"}',
        'build/main/main.js': 'console.log("fixture");',
        'build/renderer/index.html': '<html></html>',
        'src/main/static/fixture.txt': 'static asset',
        'winboat/windows.iso': 'private install media',
        'winboat/winboat-hardware.json': 'private identity',
        '.env': 'private settings',
        'helios/upstream/fixture.txt': 'build-only sources',
    };
    for (const [name, content] of Object.entries(files)) {
        await fs.mkdir(path.dirname(path.join(app, name)), { recursive: true });
        await fs.writeFile(path.join(app, name), content);
    }
    const disk = await fs.open(path.join(app, 'winboat/data.img'), 'w');
    await disk.truncate(5 * 1024 ** 3); // Sparse: reproduces the ASAR limit without allocating 5 GB.
    await disk.close();
    const config = JSON.parse(await fs.readFile('electron-builder.json', 'utf8'));
    const info = { projectDir: app, buildResourcesDir: 'build', config,
        debugLogger: { isEnabled: false }, isPrepackedAppAsar: false };
    const matchers = getMainFileMatchers(app, output, s => s, {}, { info }, path.join(app, 'dist'), false);
    assert.ok(matchers);
    // Exercise electron-builder's own copy filters, then create a real ASAR archive.
    await copyFiles(matchers, null, true);
    const archive = path.join(root, 'app.asar');
    await asar.createPackage(output, archive);
    const packed = asar.listPackage(archive);
    for (const name of ['/package.json', '/main/main.js', '/renderer/index.html', '/static/fixture.txt']) {
        assert.ok(packed.includes(name), `Missing runtime file ${name}`);
    }
    assert.ok(!packed.some(name => /winboat|\.env|upstream/.test(name)), packed.join('\n'));
    assert.ok((await fs.stat(archive)).size < 10000);
});
