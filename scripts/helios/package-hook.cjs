const path = require('node:path');
module.exports = async () => {
    const { verifyPinnedInstaller } = await import('./bundled-installer.ts');
    const root = path.resolve(__dirname, '../..');
    verifyPinnedInstaller(path.join(root, 'resources/helios'), root);
};
