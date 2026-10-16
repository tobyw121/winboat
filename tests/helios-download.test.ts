import { test, type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execute = promisify(execFile);
const moduleURL = new URL('../scripts/helios/installer-download.ts', import.meta.url).href;
const run = `import {downloadInstallerArtifact} from ${JSON.stringify(moduleURL)};
try {downloadInstallerArtifact(process.argv[1],process.argv[2],process.argv[3]);}
catch(error) {console.error(error.message);process.exitCode=1;}`;
const dummyToken = 'ghp_dummy_download_test';

async function server(t: TestContext, handler: http.RequestListener): Promise<string> {
    const instance = http.createServer(handler);
    await new Promise<void>(resolve => instance.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise<void>((resolve, reject) => instance.close(error => error ? reject(error) : resolve())));
    return `http://127.0.0.1:${(instance.address() as import('node:net').AddressInfo).port}`;
}

function fixture(t: TestContext) {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'helios-download-test-'));
    t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
    const tokenFile = path.join(directory, 'github-token');
    fs.writeFileSync(tokenFile, dummyToken + '\n', { mode: 0o600 });
    // Local HTTP fixtures must not inherit real credentials or use a proxy.
    const env = { ...process.env, GH_TOKEN: '', GITHUB_TOKEN: '', NO_PROXY: '127.0.0.1', no_proxy: '127.0.0.1' };
    const download = (url: string, secret = tokenFile, extraEnv = {}) => execute(process.execPath,
        ['--input-type=module', '-e', run, url, path.join(directory, 'artifact.zip'), secret],
        { env: { ...env, ...extraEnv }, timeout: 10000 });
    return { directory, tokenFile, download };
}

test('installer download authenticates from a secret file without forwarding credentials to redirected storage', async t => {
    const { directory, download } = fixture(t);
    let authorization: string | undefined;
    const storage = await server(t, (request, response) => {
        authorization = request.headers.authorization;
        response.end('fixture artifact bytes');
    });
    let requestAuthorization: string | undefined;
    const github = await server(t, (request, response) => {
        requestAuthorization = request.headers.authorization;
        response.writeHead(302, { Location: storage + '/artifact.zip' }); response.end();
    });
    await download(github + '/artifact');
    assert.equal(requestAuthorization, `Bearer ${dummyToken}`);
    assert.equal(authorization, undefined);
    assert.equal(fs.readFileSync(path.join(directory, 'artifact.zip'), 'utf8'), 'fixture artifact bytes');
});

test('installer HTTP 401 reports authentication and local-bundle remedies without printing the token', async t => {
    const { download } = fixture(t);
    const github = await server(t, (_request, response) => { response.writeHead(401); response.end(); });
    await assert.rejects(download(github), (error: { stderr: string; code: number }) => {
        assert.equal(error.code, 1);
        assert.match(error.stderr, /HTTP 401/);
        assert.match(error.stderr, /GH_TOKEN/);
        assert.match(error.stderr, /--installer-dir/);
        assert.ok(!error.stderr.includes(dummyToken));
        return true;
    });
});

test('installer HTTP 404 identifies unavailable or expired artifacts', async t => {
    const { download } = fixture(t);
    const github = await server(t, (_request, response) => { response.writeHead(404); response.end(); });
    await assert.rejects(download(github), (error: { stderr: string }) => {
        assert.match(error.stderr, /HTTP 404/); assert.match(error.stderr, /expired/); return true;
    });
});

test('direct installer fetch accepts GH_TOKEN when no BuildKit secret is mounted', async t => {
    const { directory, download } = fixture(t);
    let authorization: string | undefined;
    const github = await server(t, (request, response) => { authorization = request.headers.authorization; response.end('ok'); });
    await download(github, path.join(directory, 'not-mounted'), { GH_TOKEN: dummyToken });
    assert.equal(authorization, `Bearer ${dummyToken}`);
});
