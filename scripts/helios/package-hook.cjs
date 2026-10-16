const path = require('node:path');
const fs = require('node:fs');
const crypto = require('node:crypto');
module.exports = async () => {
    const { verifyPinnedInstaller } = await import('./bundled-installer.ts');
    const root = path.resolve(__dirname, '../..');
    verifyPinnedInstaller(path.join(root, 'resources/helios'), root);
    const { ATLAS_ASSETS } = await import('../../src/shared/atlas.ts');
    const playbook = fs.readFileSync(path.join(root, 'resources/atlas/AtlasPlaybook.apbx'));
    if (crypto.createHash('sha256').update(playbook).digest('hex') !== ATLAS_ASSETS[1].sha256) {
        throw new Error('Bundled Atlas playbook checksum mismatch. Refusing to package.');
    }
};
