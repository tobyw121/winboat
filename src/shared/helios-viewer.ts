import type { ChildProcess } from 'node:child_process';

export type ViewerState = 'closed' | 'opening' | 'ready' | 'failed';
export class HeliosViewer {
    private session?: { child: ChildProcess; opening: Promise<void>; cancel: () => void };
    private automatic = false;
    private retry?: ReturnType<typeof setTimeout>;
    private retryAttempt = 0;
    private automaticFailure: (message: string) => void = () => {};
    constructor(private spawn: () => ChildProcess,
        private status: (state: ViewerState, message: string) => void, private timeout = 10000, private retryDelay = 1000) {}

    /** Follow VM lifecycle without opening duplicate windows or requiring RDP. */
    setAutomatic(enabled: boolean, onFailure: (message: string) => void): void {
        this.automaticFailure = onFailure;
        if (!enabled) { this.close(); return; }
        if (this.automatic) return;
        this.automatic = enabled;
        this.retryAttempt = 0;
        this.openAutomatically();
    }
    private openAutomatically(): void {
        void this.open(this.automaticFailure).catch(() => {});
    }
    private scheduleRetry(): void {
        if (!this.automatic || this.retry || this.session) return;
        const delay = Math.min(10000, this.retryDelay * 2 ** Math.min(this.retryAttempt++, 4));
        this.status('opening', 'Waiting for the Windows console; reconnecting automatically…');
        this.retry = setTimeout(() => { this.retry = undefined; this.openAutomatically(); }, delay);
    }
    open(onFailure: (message: string) => void): Promise<void> {
        if (this.retry) { clearTimeout(this.retry); this.retry = undefined; }
        if (this.session) return this.session.opening;
        let resolve!: () => void, reject!: (error: Error) => void;
        const opening = new Promise<void>((yes, no) => { resolve = yes; reject = no; });
        let child: ChildProcess;
        try { child = this.spawn(); }
        catch (error) { this.status('failed', String(error)); onFailure(String(error)); this.scheduleRetry(); return Promise.reject(error); }
        let ready = false, closed = false, output = '', errors = '';
        this.status('opening', 'Connecting to the Windows console…');
        const finish = (message?: string, cancelled = false) => {
            if (closed) return;
            closed = true; clearTimeout(timer);
            if (this.session?.child === child) this.session = undefined;
            this.status(message && !cancelled ? 'failed' : 'closed', message && !cancelled ? message : '');
            if (!ready) reject(Object.assign(new Error(message || 'Local display closed.'), { name: cancelled ? 'AbortError' : 'Error' }));
            if (message && !cancelled) { onFailure(message); this.scheduleRetry(); }
            // A normal window close is intentional. Do not reopen until the
            // next VM lifecycle or an explicit Open Local Desktop action.
        };
        const timer = setTimeout(() => {
            finish('Local display did not become ready within 10 seconds.');
            child.kill();
        }, this.timeout);
        this.session = { child, opening, cancel: () => { finish(undefined, true); child.kill(); } };
        child.stdout?.on('data', (data: Buffer) => {
            if (closed) return;
            output = (output + data.toString()).slice(-16384);
            if (!ready && output.split('\n').slice(0, -1).includes('{"event":"ready","transport":"dbus"}')) {
                ready = true; this.retryAttempt = 0; clearTimeout(timer);
                this.status('ready', 'Local Desktop connected. Ctrl+Alt+Enter toggles fullscreen.'); resolve();
            }
        });
        child.stderr?.on('data', (data: Buffer) => { errors = (errors + data.toString()).slice(-8192); });
        child.once('error', error => finish(error.message));
        child.once('close', code => finish(code === 0 && ready ? undefined : errors || 'The local display disconnected.'));
        return opening;
    }
    close(): void {
        this.automatic = false;
        if (this.retry) { clearTimeout(this.retry); this.retry = undefined; }
        if (this.session) this.session.cancel(); else this.status('closed', '');
    }
}
