/** One bounded capture shared by repeated clicks; no VM lifecycle operations. */
export function graphicsCapture(run: () => Promise<string>) {
    let active: Promise<string> | undefined;
    return (): Promise<string> => {
        if (active) return active;
        active = run().then(stdout => {
            const path = stdout.split(/\r?\n/)[0]?.match(/^Recording: (\/[^\r\n]+)$/)?.[1];
            if (!path) throw new Error('Graphics capture did not produce a report.');
            return path;
        }).finally(() => { active = undefined; });
        return active;
    };
}
