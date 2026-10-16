import fs from 'node:fs';
import { execFileSync } from 'node:child_process';

/** Keep GitHub credentials off curl's command line and out of build logs. */
export function downloadInstallerArtifact(url: string, archive: string, tokenFile = '/run/secrets/github_token'): void {
    const token = (fs.existsSync(tokenFile) ? fs.readFileSync(tokenFile, 'utf8')
        : process.env.GH_TOKEN || process.env.GITHUB_TOKEN || '').trim();
    if (/[\r\n\0]/.test(token)) throw new Error('The GitHub token must contain a single token, without embedded line breaks.');
    const header = `Authorization: Bearer ${token}`.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
    const config = token ? `header = "${header}"\n` : '';
    try {
        // curl strips Authorization on redirects to a different origin. Do not
        // use --location-trusted: the artifact redirects to external storage.
        execFileSync('curl', ['--disable', '--config', '-', '--fail', '--location', '--silent', '--show-error',
            '--max-time', '180', '--write-out', '%{http_code}', url, '-o', archive],
        { input: config, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
    } catch (error) {
        const failure = error as { status?: number; code?: string; stdout?: string };
        const status = failure.stdout?.trim();
        const detail = status && /^[1-5][0-9]{2}$/.test(status) ? `HTTP ${status}`
            : failure.code === 'ENOENT' ? 'curl is not installed' : `curl exit ${failure.status ?? 'unknown'}`;
        const cause = status === '401' || status === '403'
            ? 'GitHub refused access. Supply GH_TOKEN or GITHUB_TOKEN with Actions read access to winboat-org/helios.'
            : status === '404' || status === '410'
                ? 'The pinned artifact may be expired, missing, or inaccessible to this GitHub account.'
                : failure.status === 60 ? 'TLS certificate verification failed. Configure HELIOS_PROXY_CA with your trusted CA bundle.'
                    : 'Check network access, proxy settings and GitHub artifact availability.';
        throw new Error(`Helios installer download failed (${detail}). ${cause}\n`
            + 'Alternatively use ./scripts/build-helios.sh --installer-dir /path/to/bundle with HeliosSetup.exe and helios-build.json.');
    }
}
