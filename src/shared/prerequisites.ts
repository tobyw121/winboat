import type { Specs } from '../types';

export function satisfiesPrequisites(specs: Specs) {
    return specs.dockerInstalled &&
        specs.dockerComposeInstalled &&
        specs.dockerIsRunning &&
        specs.dockerIsInUserGroups &&
        specs.kvmEnabled &&
        specs.ramGB >= 4 &&
        specs.cpuCores >= 2
}

export const defaultSpecs: Specs = {
    cpuCores: 0,
    ramGB: 0,
    kvmEnabled: false,
    dockerInstalled: false,
    dockerComposeInstalled: false,
    dockerIsRunning: false,
    dockerIsInUserGroups: false,
    freeRDP3Installed: false
}

