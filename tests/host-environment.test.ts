import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { build } from 'vite';
import { createRequire } from 'node:module';

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

test('Local Desktop preference is persisted and reloaded independently of the active Compose transport', async () => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'winboat-preference-'));
    try {
        const source = path.resolve('src/renderer/lib/config.ts').replaceAll('\\', '/');
        await fs.writeFile(path.join(root,'entry.ts'), `import {WinboatConfig} from ${JSON.stringify(source)}; window.config=new WinboatConfig();`);
        const result = await build({configFile:false,root,logLevel:'silent',build:{write:false,modulePreload:{polyfill:false},rollupOptions:{input:path.join(root,'entry.ts')}}});
        assert(!Array.isArray(result) && 'output' in result);
        const output = result.output.find(item => item.type === 'chunk'); assert(output && 'code' in output);
        const nativeRequire = createRequire(import.meta.url);
        const reload = () => {
            const window: {config?: {config:{localDisplayPreferred?:boolean}}} = {};
            vm.runInNewContext(output.code, {window,console:{log(){},info(){},error(){}},require:(name:string) => name === 'os' ? {...os,homedir:()=>root} : nativeRequire(name)});
            return window.config!;
        };
        const config = reload(); assert.equal(config.config.localDisplayPreferred,undefined);
        config.config.localDisplayPreferred=true;
        assert.equal(reload().config.localDisplayPreferred,true);
        assert.equal(JSON.parse(await fs.readFile(path.join(root,'.winboat/winboat.config.json'),'utf8')).localDisplayPreferred,true);
        reload().config.localDisplayPreferred=false;
        assert.equal(reload().config.localDisplayPreferred,false);
    } finally {await fs.rm(root,{recursive:true,force:true});}
});

test('Windows installation opens its native console before the guest health API is ready', async () => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'winboat-install-console-'));
    try {
        const source = path.resolve('src/renderer/lib/install.ts').replaceAll('\\', '/');
        await fs.writeFile(path.join(root, 'entry.ts'), `
            import {InstallManager} from ${JSON.stringify(source)};
            window.manager = new InstallManager({});
            window.manager.localDisplayConfigured = window.native;
            window.manager.checkContainer = async () => {};
            window.manager.portMgr.value = {getHostPort: () => 7148};
            window.run = () => window.manager.monitorAPIHealth();
        `);
        const result = await build({configFile:false, root, logLevel:'silent', plugins:[{
            name:'installation-console-fixture',
            enforce:'pre',
            resolveId(id, importer) {
                if (id === './helios-display' && importer?.endsWith('/lib/install.ts')) return '\0display-fixture';
                if (id === '../utils/port' && importer?.endsWith('/lib/install.ts')) return '\0ports-fixture';
            },
            load(id) {
                if (id === '\0ports-fixture') return 'export class PortManager {}';
                if (id === '\0display-fixture') return `
                    export function followLocalDisplay(enabled) {
                        if (enabled) window.opens++;
                        window.reconnecting = enabled && window.viewerFails;
                    }
                    export async function prepareLocalDisplay() {}
                    export function localDisplayDirectory() {return '/tmp/display-fixture';}
                `;
            },
        }], build:{write:false, modulePreload:{polyfill:false}, rollupOptions:{input:path.join(root,'entry.ts')}}});
        assert(!Array.isArray(result) && 'output' in result);
        const output = result.output.find(item => item.type === 'chunk'); assert(output && 'code' in output);
        const nativeRequire = createRequire(import.meta.url);
        for (const [native, viewerFails] of [[true,false], [true,true], [false,false]]) {
            const window = {native, viewerFails, opens:0} as {
                native:boolean; viewerFails:boolean; opens:number;
                manager:{state:string}; run:()=>Promise<void>; health?:(response:{status:number})=>void;
            };
            vm.runInNewContext(output.code, {window, process, setTimeout, clearTimeout,
                console:{log(){},info(){},warn(){},error(){}}, require:(name:string) => {
                    if (name === 'os') return {...os,homedir:()=>root};
                    if (name === '@electron/remote') return {app:{isPackaged:false}};
                    if (name === 'node-fetch') return () => new Promise(resolve => {window.health=resolve;});
                    return nativeRequire(name);
                }});
            const installing = window.run();
            await new Promise(resolve => setImmediate(resolve));
            assert.equal(window.manager.state,'Installing Windows');
            assert.equal(window.opens,native?1:0);
            assert.ok(window.health,'installation is still waiting for Windows, with the console already opened');
            window.health({status:200});
            await installing; // A viewer failure must not abort Windows installation.
        }
    } finally {await fs.rm(root,{recursive:true,force:true});}
});
