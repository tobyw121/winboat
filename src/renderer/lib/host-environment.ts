// Vite replaces direct process.env access in client bundles with an empty object.
// Electron's Node process still owns the host desktop/runtime environment.
export function hostEnvironment(): NodeJS.ProcessEnv {
    const nodeProcess: typeof import('process') = require('process');
    return nodeProcess.env;
}
