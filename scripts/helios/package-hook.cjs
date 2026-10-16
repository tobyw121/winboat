const path = require('node:path');
module.exports = async () => {
    const { verifyBundle } = await import('./bundle.ts');
    verifyBundle(path.resolve(__dirname, '../../resources/helios'));
};
