export type VMResources = {cpu: number; ram: number};

// Existing allocations can exceed today's detected limits (for example when
// physical cores are reported instead of SMT threads). Unrelated edits must
// not require changing a working VM's CPU or memory allocation.
export function changedResourceErrors(current: VMResources, saved: VMResources, maximum: VMResources): string[] {
    const errors: string[] = [];
    if (current.cpu !== saved.cpu) {
        if (!Number.isInteger(current.cpu) || current.cpu < 2) errors.push('Allocate at least two CPU cores.');
        else if (current.cpu > maximum.cpu) errors.push('The CPU allocation exceeds the available logical CPUs.');
    }
    if (current.ram !== saved.ram) {
        if (!Number.isFinite(current.ram) || current.ram < 4) errors.push('Allocate at least 4 GB of RAM.');
        else if (current.ram > maximum.ram) errors.push('The RAM allocation exceeds available host memory.');
    }
    return errors;
}
