import type { ChildProcess } from 'node:child_process';

export function viewerWire(line:string):string|undefined {
    return /^frame-wire peer=[a-f0-9]{32} serial=[0-9]{1,10} stage=(receive|ack|render|drop) method=(Scanout|Update|ScanoutDMABUF|ScanoutDMABUF2|UpdateDMABUF|Disable|Cached) monotonic_us=[0-9]{1,20}$/.test(line)?line:undefined;
}
/** Preserve exact 64-bit metadata as a bounded numeric-only JSON line. */
export function viewerContract(line:string):string|undefined {
    return /^\{"event":"dmabuf-contract","console":\d{1,10},"inode":\d{1,20},"bytes":\d{1,20},"width":\d{1,10},"height":\d{1,10},"stride":\d{1,10},"offset":\d{1,10},"fourcc":\d{1,10},"modifier":\d{1,20}\}$/.test(line)?line:undefined;
}
export function viewerStatistics(line:string):Record<string,number>|undefined {
    let value:Record<string,unknown>;
    try {value=JSON.parse(line);} catch {return;}
    if(!value || value.event!=='statistics')return;
    const clean:Record<string,number>={};
    for(const key of ['pid','console','monotonicUs','requestedTransportMode','accelerated','width','height','dmabufFrames','softwareFrames','renderedFrames','sourceCopyWallUs','completionWaitUs','copySamples','skippedRedraws','coalescedUpdates','sourceInode']){
        const n=value[key];if(typeof n==='number' && Number.isSafeInteger(n) && n>=0)clean[key]=n;
    }
    if(['pid','console','monotonicUs'].every(key=>key in clean))return clean;
}
export type ViewerState = 'closed' | 'opening' | 'ready' | 'failed';
export class HeliosViewer {
    private session?: { child: ChildProcess; opening: Promise<void>; cancel: () => void };
    private adapterCommand = 'adapters 0 0\n';
    /** Unknown guest health cannot promote an unverified Helios boot surface. */
    updateAdapters(value: unknown): void {
        type Adapter = {state?:string;desktopState?:string};
        const candidate = value as {helios?:Adapter;basic?:Adapter;sampleAgeMs?:number} | null;
        const state = (adapter?:Adapter) => {
            if (['disabled','failed','missing'].includes(adapter?.state || '')) return 2;
            if (adapter?.state !== 'running') return 0;
            if (adapter.desktopState === 'inactive') return 3;
            if (adapter.desktopState !== undefined && adapter.desktopState !== 'active') return 0;
            return 1; // Legacy API, or a confirmed active Windows output.
        };
        // A monotonic sample age avoids dependence on the Windows wall clock.
        const age = candidate?.sampleAgeMs;
        const fresh = typeof age === 'number' && Number.isFinite(age) && age>=0 && age<15000;
        this.adapterCommand = `adapters ${fresh?state(candidate?.helios):0} ${fresh?state(candidate?.basic):0}\n`;
        this.sendAdapters();
    }
    private sendAdapters(): void {
        const input = this.session?.child.stdin;
        if (input?.writable && !input.destroyed) input.write(this.adapterCommand);
    }
    private automatic = false;
    private retry?: ReturnType<typeof setTimeout>;
    private retryAttempt = 0;
    private automaticFailure: (message: string) => void = () => {};
    constructor(private spawn: () => ChildProcess,
        private status: (state: ViewerState, message: string) => void, private timeout = 10000, private retryDelay = 1000, private recovery?: (unavailable:boolean)=>void,private telemetry?: (row:Record<string,number>)=>void,private wire?: (line:string)=>void) {}

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
        let ready = false, closed = false, output = '', errors = '', metrics='';let lastMetricAt=-Infinity,wireWindow=0,wireCount=0;
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
        child.stdin?.on('error', () => {}); // A window close can race an in-flight health update.
        this.sendAdapters();
        child.stdout?.on('data', (data: Buffer) => {
            if (closed) return;
            output = (output + data.toString()).slice(-16384);
            const lines=output.split('\n');output=lines.pop() || '';
            for (const line of lines) {
                const wire=viewerWire(line),now=Date.now();
                if(now-wireWindow>=1000){wireWindow=now;wireCount=0;}
                if(wire && wireCount++<32){try{this.wire?.(wire);}catch{/* Optional tracing cannot stop the viewer. */}}
                let event: {event?:string;transport?:string;console?:number;reason?:string;accelerated?:boolean};
                try {event=JSON.parse(line);} catch {continue;}
                if (!event || typeof event !== 'object') continue;
                if (!ready && event.event === 'ready' && event.transport === 'dbus') {
                    ready = true; this.retryAttempt = 0; clearTimeout(timer);
                    this.status('ready', 'Local Desktop connected. Ctrl+Alt+Enter toggles fullscreen.'); resolve();
                } else if (ready && event.event === 'display-recovery' && typeof event.reason === 'string') {
                    const message=`Display ${event.console}: ${event.reason.slice(0,512)}. Reconnecting this display automatically…`;
                    console.warn(message);this.status('ready',message);
                    if (event.accelerated === true) this.recovery?.(true);
                } else if (ready && event.event === 'display-recovered') {
                    if (event.accelerated === true) this.recovery?.(false);
                    this.status('ready','Local Desktop connected. Ctrl+Alt+Enter toggles fullscreen.');
                }
            }
        });
        child.stderr?.on('data', (data: Buffer) => {
            if(closed)return;
            errors = (errors + data.toString()).slice(-8192);
            metrics=(metrics+data.toString()).slice(-16384);const lines=metrics.split('\n');metrics=lines.pop()||'';
            for(const line of lines){const row=viewerStatistics(line),contract=viewerContract(line),now=Date.now();
                if(now-wireWindow>=1000){wireWindow=now;wireCount=0;}
                if(contract && wireCount++<32){try{this.wire?.(contract);}catch{/* Layout tracing cannot stop display. */}}
                if(row && Date.now()-lastMetricAt>=1000){lastMetricAt=Date.now();try{this.telemetry?.(row);}catch{/* Diagnostics cannot stop the display. */}}
            }
        });
        child.once('error', error => finish(error.message));
        child.once('close', code => finish(code === 0 && ready ? undefined : errors || 'The local display disconnected.'));
        return opening;
    }
    close(): void {
        this.adapterCommand = 'adapters 0 0\n';
        this.automatic = false;
        if (this.retry) { clearTimeout(this.retry); this.retry = undefined; }
        if (this.session) this.session.cancel(); else this.status('closed', '');
    }
}
