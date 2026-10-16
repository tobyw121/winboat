/** Docker restarts are distinct from a Windows reboot inside a running QEMU VM. */
export function containerInstallFailure(info: { State?: { Status?: string; Running?: boolean; Restarting?: boolean; ExitCode?: number; OOMKilled?: boolean }; RestartCount?: number }, initialRestarts = 0): string | undefined {
    const state = info.State;
    if (!state) throw new Error('Docker returned no VM container state.');
    if (state.OOMKilled) return 'The Windows VM container was terminated because it ran out of memory.';
    if (state.Restarting || (info.RestartCount || 0) > initialRestarts) {
        return 'The Windows VM container crashed and restarted. Inspect docker logs WinBoat.';
    }
    if (!state.Running || state.Status !== 'running') {
        return `The Windows VM container stopped (${state.Status || 'unknown'}, exit ${state.ExitCode ?? 'unknown'}). Inspect docker logs WinBoat.`;
    }
}
