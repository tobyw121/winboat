import { configureHelios, validateHeliosProgress, HELIOS_REVISION } from '../../shared/helios';
import { requireHelios, heliosBundlePath } from './helios';
import { configureVmIdentity } from '../../shared/vm-identity';
import { loadOrCreateVmIdentity } from '../../shared/vm-identity-store';
import { validateAtlasSelection, validateAtlasProgress, configureAtlasIso, ATLAS_ISO_LABEL, ATLAS_ISO_VERSION } from '../../shared/atlas';
import { stageAtlasBundle } from '../../shared/atlas-bundle';
import { containerInstallFailure, containerInstallLogFailure } from '../../shared/install-container';
import { type ComposeConfig, type InstallConfiguration } from "../../types";
import {
    GUEST_API_PORT,
    GUEST_NOVNC_PORT,
    RESTART_ON_FAILURE,
    WINBOAT_DIR,
} from "./constants";
import YAML from "json-to-pretty-yaml";
import { ref, type Ref } from "vue";
import { createLogger } from "../utils/log";
import { createNanoEvents, type Emitter } from "nanoevents";
import { PortManager } from "../utils/port";
const fs: typeof import('fs') = require('fs');
const { exec, execFile }: typeof import('child_process') = require('child_process');
const path: typeof import('path') = require('path');
const { promisify }: typeof import('util') = require('util');
const nodeFetch: typeof import('node-fetch').default = require('node-fetch');
const remote: typeof import('@electron/remote') = require('@electron/remote');

const execAsync = promisify(exec);
const execFileAsync = promisify(execFile);
const logger = createLogger(path.join(WINBOAT_DIR, 'install.log'));

const composeFilePath = path.join(WINBOAT_DIR, 'docker-compose.yml');

export const DefaultCompose: ComposeConfig = {
    "name": "winboat",
    "volumes": {
        "data": null
    },
    "services": {
        "windows": {
            "image": "ghcr.io/dockur/windows:5.07",
            "container_name": "WinBoat",
            "environment": {
                "VERSION": "11",
                "RAM_SIZE": "4G",
                "CPU_CORES": "4",
                "DISK_SIZE": "64G",
                "USERNAME": "MyWindowsUser",
                "PASSWORD": "MyWindowsPassword",
                "HOME": "${HOME}",
                "LANGUAGE": "English",
                "HOST_PORTS": "7149",
                "ARGUMENTS": "-qmp tcp:0.0.0.0:7149,server,wait=off",
            },
            "cap_add": [
                "NET_ADMIN"
            ],
            "privileged": true,
            "ports": [
                "8006:8006", // VNC Web Interface
                "7148:7148", // Winboat Guest Server API
                "8149:7149", // QEMU QMP Port
                "3389:3389/tcp", // RDP
                "3389:3389/udp" // RDP
            ],
            "stop_grace_period": "120s",
            "restart": RESTART_ON_FAILURE,
            "volumes": [
                "data:/storage",
                "${HOME}:/shared",
                "/dev/bus/usb:/dev/bus/usb", // QEMU Synamic USB Passthrough
                "./oem:/oem",
            ],
            "devices": [
                "/dev/kvm",
            ]
        }
    }
}
export const InstallStates = {
    IDLE: 'Preparing',
    CREATING_COMPOSE_FILE: 'Creating Compose File',
    CREATING_OEM: "Creating OEM Assets",
    STARTING_CONTAINER: 'Starting Container',
    MONITORING_PREINSTALL: 'Monitoring Preinstall',
    INSTALLING_WINDOWS: 'Installing Windows',
    INSTALLING_HELIOS: 'Installing Helios graphics driver',
    PREPARING_ATLAS: 'Preparing AME and the bundled Atlas playbook',
    INSTALLING_ATLAS: 'Applying Atlas in Windows (check the Windows console)',
    COMPLETED: 'Completed',
    INSTALL_ERROR: 'Install Error'
} as const;

export type InstallState = typeof InstallStates[keyof typeof InstallStates];
interface InstallEvents {
    stateChanged: (state: InstallState) => void;
    preinstallMsg: (msg: string) => void;
    error: (error: Error) => void;
}

export class InstallManager {
    conf: InstallConfiguration;
    emitter: Emitter<InstallEvents>;
    state: InstallState;
    preinstallMsg: string;
    portMgr: Ref<PortManager | null>;
    private containerRestarts: number | undefined;
    private nextContainerCheck = 0;

    constructor(conf: InstallConfiguration) {
        this.conf = conf;
        this.state = InstallStates.IDLE;
        this.preinstallMsg = ""
        this.emitter = createNanoEvents<InstallEvents>();
        this.portMgr = ref(null);
    }

    changeState(newState: InstallState) {
        this.state = newState;
        this.emitter.emit('stateChanged', newState);
        logger.info(`New state: "${newState}"`);
    }

    setPreinstallMsg(msg: string) {
        if (msg === this.preinstallMsg) return;
        this.preinstallMsg = msg;
        this.emitter.emit('preinstallMsg', msg);
        logger.info(`Preinstall: "${msg}"`);
    }

    sleep(ms: number) {
        return new Promise(resolve => setTimeout(resolve, ms));
    }

    async createComposeFile() {
        validateAtlasSelection(this.conf.atlasEnabled, this.conf.windowsVersion, this.conf.customIsoPath);
        if (this.conf.atlasEnabled && fs.existsSync(this.conf.installFolder) &&
            fs.readdirSync(this.conf.installFolder).some(name => /^(data.*|windows|system)\.(img|qcow2?|raw|vhdx?|vmdk)$/i.test(name))) {
            throw new Error('Atlas setup is available for a new VM only. Select a new installation directory. Existing disks will not be modified.');
        }
        this.changeState(InstallStates.CREATING_COMPOSE_FILE);

        // Ensure the .winboat directory exists
        if (!fs.existsSync(WINBOAT_DIR)) {
            fs.mkdirSync(WINBOAT_DIR);
            logger.info(`Created WinBoat directory: ${WINBOAT_DIR}`);
        }

        // Ensure the installation directory exists
        if (!fs.existsSync(this.conf.installFolder)) {
            fs.mkdirSync(this.conf.installFolder, { recursive: true });
            logger.info(`Created installation directory: ${this.conf.installFolder}`);
        }

        // Configure the compose file
        const composeContent = JSON.parse(JSON.stringify(DefaultCompose)) as ComposeConfig;
        this.portMgr.value = await PortManager.parseCompose(composeContent);

        composeContent.services.windows.ports = this.portMgr.value.composeFormat;
        composeContent.services.windows.environment.RAM_SIZE = `${this.conf.ramGB}G`;
        composeContent.services.windows.environment.CPU_CORES = `${this.conf.cpuCores}`;
        composeContent.services.windows.environment.DISK_SIZE = `${this.conf.diskSpaceGB}G`;
        composeContent.services.windows.environment.VERSION = this.conf.windowsVersion;
        composeContent.services.windows.environment.LANGUAGE = this.conf.windowsLanguage;
        composeContent.services.windows.environment.USERNAME = this.conf.username;
        composeContent.services.windows.environment.PASSWORD = this.conf.password;
        const host = this.conf.heliosEnabled ? await requireHelios() : undefined;
        composeContent.services.windows = configureHelios(composeContent.services.windows,
            this.conf.heliosEnabled, host?.renderNode, host?.nvidia);
        if (this.conf.hardwareIdentityEnabled) {
            const os: typeof import('os') = require('os');
            const hardwareIdentity = loadOrCreateVmIdentity(fs, this.conf.installFolder,
                os.cpus()[0]?.model || '');
            composeContent.services.windows = configureVmIdentity(composeContent.services.windows, hardwareIdentity, this.conf.reduceCpuMarkers);
        }
        if (this.conf.atlasEnabled) {
            composeContent.services.windows = configureAtlasIso(composeContent.services.windows, this.conf.atlasMode);
            const { stdout } = await execFileAsync('docker', ['image', 'inspect', '--format',
                `{{ index .Config.Labels "${ATLAS_ISO_LABEL}" }}`, composeContent.services.windows.image]);
            if (stdout.trim() !== ATLAS_ISO_VERSION) throw new Error('The host image lacks AME OOBE/offline tools. Rebuild with scripts/build-helios.sh.');
        }

        // Boot image mapping
        if (this.conf.customIsoPath) {
            composeContent.services.windows.volumes.push(`${this.conf.customIsoPath}:/boot.iso:ro`);
        }

        // Storage folder mapping
        const storageFolderIdx = composeContent.services.windows.volumes.findIndex(vol => vol.includes('/storage'));
        if (storageFolderIdx !== -1) {
            composeContent.services.windows.volumes[storageFolderIdx] = `${this.conf.installFolder}:/storage`;
        } else {
            logger.warn("No /storage volume found in compose template, adding one...");
            composeContent.services.windows.volumes.push(`${this.conf.installFolder}:/storage`);
        }

        // Home folder mapping
        if (!this.conf.shareHomeFolder) {
            const sharedFolderIdx = composeContent.services.windows.volumes.findIndex(vol => vol.includes('/shared'));
            if (sharedFolderIdx !== -1) {
                composeContent.services.windows.volumes.splice(sharedFolderIdx, 1);
                logger.info("Removed home folder sharing as per user configuration");
            } else {
                logger.info("No home folder sharing volume found, nothing to remove");
            }
        }

        // Write the compose file
        const composeYAML = YAML.stringify(composeContent).replaceAll("null", "");
        fs.writeFileSync(composeFilePath, composeYAML, { encoding: 'utf8' });
        logger.info(`Creating compose file at: ${composeFilePath}`);

    }

    createOEMAssets() {
        this.changeState(InstallStates.CREATING_OEM);
        logger.info("Creating OEM assets");

        const oemPath = path.join(WINBOAT_DIR, 'oem'); // Fixed the path separator

        // Create OEM directory if it doesn’t exist
        if (!fs.existsSync(oemPath)) {
            fs.mkdirSync(oemPath, { recursive: true });
            logger.info(`Created OEM directory: ${oemPath}`);
        }

        // Determine the source path based on whether the app is bundled
        const appPath = remote.app.isPackaged 
            ? path.join(process.resourcesPath, 'guest_server') // For packaged app
            : path.join(remote.app.getAppPath(), '..', '..', 'guest_server'); // For dev mode

        logger.info(`Guest server source path: ${appPath}`);

        // Check if the source directory exists
        if (!fs.existsSync(appPath)) {
            const error = new Error(`Guest server directory not found at: ${appPath}`);
            logger.error(error.message);
            this.changeState(InstallStates.INSTALL_ERROR);
            throw error;
        }

        const copyRecursive = (src: string, dest: string) => {
            const stats = fs.statSync(src);
            
            if (stats.isDirectory()) {
                // Create directory if it doesn't exist
                if (!fs.existsSync(dest)) {
                    fs.mkdirSync(dest, { recursive: true });
                }
                
                // Copy all contents
                fs.readdirSync(src).forEach(entry => {
                    const srcPath = path.join(src, entry);
                    const destPath = path.join(dest, entry);
                    copyRecursive(srcPath, destPath);
                });
                
                logger.info(`Copied directory ${src} to ${dest}`);
            } else {
                // Copy file
                fs.copyFileSync(src, dest);
                logger.info(`Copied file ${src} to ${dest}`);
            }
        };

        // Copy all files from guest_server to oemPath
        try {
            fs.readdirSync(appPath).forEach(entry => {
                const srcPath = path.join(appPath, entry);
                const destPath = path.join(oemPath, entry);
                copyRecursive(srcPath, destPath);
            });
            const profileTools = path.join(oemPath, '.winboat-hardware');
            const atlasTools = path.join(oemPath, '.winboat-atlas');
            if (this.conf.atlasEnabled) {
                const source = remote.app.isPackaged ? path.join(process.resourcesPath, 'atlas-tools')
                    : path.join(remote.app.getAppPath(), '..', '..', 'resources', 'atlas-tools');
                fs.mkdirSync(atlasTools, { recursive: true });
                for (const file of ['entry.sh', 'inject.sh', 'inject.py', 'ame_assets.py', 'offline_registry.py']) fs.copyFileSync(path.join(source, file), path.join(atlasTools, file));
            } else fs.rmSync(atlasTools, { recursive: true, force: true });
            if (this.conf.hardwareIdentityEnabled) {
                const source = remote.app.isPackaged ? path.join(process.resourcesPath, 'vm-profile')
                    : path.join(remote.app.getAppPath(), '..', '..', 'resources', 'vm-profile');
                fs.mkdirSync(profileTools, { recursive: true });
                for (const file of ['entry.sh', 'config.sh']) fs.copyFileSync(path.join(source, file), path.join(profileTools, file));
            } else fs.rmSync(profileTools, { recursive: true, force: true });
            if (this.conf.heliosEnabled) {
                const bundle = heliosBundlePath();
                const target = path.join(oemPath, 'helios');
                fs.mkdirSync(target, { recursive: true });
                for (const name of ['HeliosSetup.exe', 'helios-build.json']) {
                    fs.copyFileSync(path.join(bundle, name), path.join(target, name));
                }
                fs.writeFileSync(path.join(oemPath, 'helios-enabled'), '1');
            } else {
                fs.rmSync(path.join(oemPath, 'helios-enabled'), { force: true });
                fs.rmSync(path.join(oemPath, 'helios'), { recursive: true, force: true });
            }
            logger.info("OEM assets created successfully");
        } catch (error) {
            logger.error(`Failed to copy OEM assets: ${error}`);
            this.changeState(InstallStates.INSTALL_ERROR);
            throw error;
        }
    }

    async startContainer() {
        this.changeState(InstallStates.STARTING_CONTAINER);
        logger.info('Starting container...');

        // Start the container
        try {
            // execSync(`docker compose -f ${composeFilePath} up -d`, { stdio: 'inherit' });
            const { stdout, stderr } = await execAsync(`docker compose -f ${composeFilePath} up -d`);
            if (stderr) {
                logger.error(stderr);
            }
        } catch (e) {
            this.changeState(InstallStates.INSTALL_ERROR);
            logger.error('Failed to start container.');
            logger.error(e);
            throw e;
        }
        logger.info('Container started successfully.');
        this.containerRestarts = undefined;
        this.nextContainerCheck = 0;
        await this.checkContainer();
    }

    async readContainerFailure() {
        try {
            const logs = await execFileAsync('docker', ['logs', '--tail', '80', 'WinBoat'], { timeout: 5000 });
            return containerInstallLogFailure(logs.stdout + '\n' + logs.stderr);
        } catch { return undefined; }
    }

    async checkContainer(force = false) {
        if (!force && Date.now() < this.nextContainerCheck) return;
        this.nextContainerCheck = Date.now() + 5000;
        const { stdout } = await execFileAsync('docker', ['inspect', 'WinBoat'], { timeout: 10000 });
        const info = JSON.parse(stdout)[0];
        const failure = containerInstallFailure(info, this.containerRestarts ?? info.RestartCount);
        if (failure) {
            const reason = await this.readContainerFailure();
            throw new Error(failure + (reason ? ` ${reason}` : ''));
        }
        this.containerRestarts ??= info.RestartCount || 0;
    }

    async prepareAtlas() {
        const target = path.join(WINBOAT_DIR, 'oem', 'atlas');
        fs.rmSync(path.join(WINBOAT_DIR, 'oem', 'atlas-enabled'), { force: true });
        if (!this.conf.atlasEnabled) {
            fs.rmSync(target, { recursive: true, force: true });
            return;
        }
        this.changeState(InstallStates.PREPARING_ATLAS);
        const crypto: typeof import('crypto') = require('crypto');
        const bundledAtlas = remote.app.isPackaged ? path.join(process.resourcesPath, 'atlas')
            : path.join(remote.app.getAppPath(), '..', '..', 'resources', 'atlas');
        await stageAtlasBundle(fs, path, data => crypto.createHash('sha256').update(data).digest('hex'),
            target, this.conf.username, this.conf.heliosEnabled, async url => {
                const response = await nodeFetch(url, { timeout: 300000, size: 192 * 1024 * 1024 });
                if (!response.ok) throw new Error(`Atlas download failed: HTTP ${response.status}. Check your network and try again.`);
                return response.buffer();
            }, msg => this.setPreinstallMsg(msg), this.conf.atlasMode, bundledAtlas, this.conf.password);
        fs.writeFileSync(path.join(WINBOAT_DIR, 'oem', 'atlas-enabled'), '1');
    }

    async monitorContainerPreinstall() {
        // Sleep a bit to make sure the webserver is up in the container
        await this.sleep(3000);

        this.changeState(InstallStates.MONITORING_PREINSTALL);
        logger.info('Starting preinstall monitoring...');

        while (true) {
            await this.checkContainer();
            try {
                const vncHostPort = this.portMgr.value!.getHostPort(GUEST_NOVNC_PORT);
                const response = await nodeFetch(`http://127.0.0.1:${vncHostPort}/msg.html`);
                if (response.status === 404) {
                    logger.info('Received 404, preinstall completed');
                    return; // Exit the method when we get 404
                }
                const message = await response.text();
                const re = />([^<]+)</;
                const messageFormatted = message.match(re)?.[1] || message;
                this.setPreinstallMsg(messageFormatted);
            } catch (error) {
                if (error instanceof Error && error.message.includes('404')) {
                    logger.info('Received 404, preinstall completed');
                    return; // Exit the method when fetch throws 404
                }
                // A preparation crash can reset HTTP before Docker reports its restart.
                const reason = await this.readContainerFailure();
                if (reason) throw new Error(reason);
                await this.checkContainer(true);
                logger.error(`Error monitoring container: ${error}`);
                this.changeState(InstallStates.INSTALL_ERROR);
                throw error;
            }

            // Wait 500ms before next check
            await new Promise(resolve => setTimeout(resolve, 500));
        }
    }

    async monitorAPIHealth() {
        this.changeState(InstallStates.INSTALLING_WINDOWS);
        logger.info("Waiting for WinBoat Guest Server to wrap up installation...");

        let attempts = 0;

        while (true) {
            await this.checkContainer();
            try {
                const apiHostPort = this.portMgr.value!.getHostPort(GUEST_API_PORT);
                const res = await nodeFetch(`http://127.0.0.1:${apiHostPort}/health`, { timeout: 5000 });
                if (res.status === 200) {
                    logger.info("WinBoat Guest Server is up and healthy!");
                    return;
                }
                // Log every 60 seconds (every 12th attempt with 5-second intervals)
                if (attempts % 12 === 0) {
                    logger.info(`API not ready yet (status: ${res.status}), still waiting after ${attempts * 5 / 60} minutes...`);
                }
            } catch (error) {
                // Log every 60 seconds for errors too
                if (attempts % 12 === 0) {
                    logger.info(`API not responding yet, still waiting after ${attempts * 5 / 60} minutes...`);
                }
            }

            attempts++;
            await this.sleep(5000); // Wait 5 seconds between tries
        }
    }

    async monitorHelios() {
        this.changeState(InstallStates.INSTALLING_HELIOS);
        const deadline = Date.now() + 45 * 60 * 1000;
        const port = this.portMgr.value!.getHostPort(GUEST_API_PORT);
        while (Date.now() < deadline) {
            await this.checkContainer();
            let response;
            try { response = await nodeFetch(`http://127.0.0.1:${port}/graphics/helios`, { timeout: 5000 }); }
            catch { await this.sleep(5000); continue; } // Expected while Windows restarts.
            if (response.status === 503) { await this.sleep(5000); continue; }
            if (!response.ok) throw new Error(`Helios status API returned HTTP ${response.status}. Update the Windows guest server.`);
            const progress = validateHeliosProgress(await response.json());
            this.setPreinstallMsg(progress.message || progress.status);
            if (progress.status === 'finished') {
                // The next container start can remove the installation VGA.
                // Never interrupt Windows/AME by recreating this running VM.
                const marker = path.join(this.conf.installFolder, '.winboat-helios-ready');
                const temporary = `${marker}.${process.pid}.${Date.now()}.tmp`;
                fs.writeFileSync(temporary, `${HELIOS_REVISION}\n`, { flag: 'wx', mode: 0o600 });
                fs.renameSync(temporary, marker);
                return;
            }
            await this.sleep(5000);
        }
        throw new Error('Helios installation timed out. Inspect C:\\ProgramData\\Helios\\logs\\setup.log in Windows.');
    }

    async monitorAtlas() {
        this.changeState(InstallStates.INSTALLING_ATLAS);
        const port = this.portMgr.value!.getHostPort(GUEST_API_PORT);
        const deadline = Date.now() + 120 * 60 * 1000;
        while (Date.now() < deadline) {
            await this.checkContainer();
            let response;
            try { response = await nodeFetch(`http://127.0.0.1:${port}/provisioning/atlas`, { timeout: 5000 }); }
            catch { await this.sleep(5000); continue; }
            if (!response.ok) throw new Error(`Atlas status API returned HTTP ${response.status}. Inspect the Windows console.`);
            const progress = validateAtlasProgress(await response.json());
            this.setPreinstallMsg(progress.message);
            if (progress.status === 'finished') return;
            await this.sleep(5000);
        }
        throw new Error('Atlas setup is still pending. Open the Windows console and inspect C:\\ProgramData\\WinBoat\\Atlas\\status.json.');
    }

    async install() {
        logger.info('Starting installation...');

        try {
            await this.createComposeFile();
            this.createOEMAssets();
            await this.prepareAtlas();
            await this.startContainer();
            await this.monitorContainerPreinstall();
            await this.monitorAPIHealth();
            if (this.conf.atlasEnabled && this.conf.atlasMode === 'iso') await this.monitorAtlas();
            if (this.conf.heliosEnabled) await this.monitorHelios();
            if (this.conf.atlasEnabled && this.conf.atlasMode === 'live') await this.monitorAtlas();
            this.changeState(InstallStates.COMPLETED);

            logger.info('Installation completed successfully.');
        } catch (error) {
            this.changeState(InstallStates.INSTALL_ERROR);
            this.setPreinstallMsg(error instanceof Error ? error.message : String(error));
            this.emitter.emit('error', error instanceof Error ? error : new Error(String(error)));
            throw error;
        }
    }
}

export async function isInstalled() {
    // Check if a docker container named WinBoat exists
    try {
        const { stdout: res } = await execAsync('docker ps -a --filter "name=WinBoat" --format "{{.Names}}"');
        return res.includes('WinBoat');
    } catch(e) {
        logger.error("Failed to get WinBoat status, is Docker installed?");
        logger.error(e);
        return false;
    }
}
