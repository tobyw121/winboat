import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import mockFs from 'mock-fs';

import { checkVirglSupport, hasVirglDeviceMapping } from '../src/renderer/utils/gpu';

test('checkVirglSupport returns false when /dev/dri is missing', t => {
    mockFs({});
    t.after(() => mockFs.restore());

    assert.equal(checkVirglSupport(), false);
});

test('checkVirglSupport returns false when no matching devices exist', t => {
    mockFs({
        '/dev/dri': {
            'not-a-card': '',
            'foo': '',
        },
    });
    t.after(() => mockFs.restore());

    assert.equal(checkVirglSupport(), false);
});

test('checkVirglSupport returns true when render or card devices are present', t => {
    mockFs({
        '/dev/dri': {
            'card0': '',
            'renderD128': '',
        },
    });
    t.after(() => mockFs.restore());

    assert.equal(checkVirglSupport(), true);
});

test('checkVirglSupport gracefully handles fs errors', t => {
    const originalReaddir = fs.readdirSync;
    fs.readdirSync = () => {
        throw new Error('boom');
    };
    t.after(() => {
        fs.readdirSync = originalReaddir;
    });

    assert.equal(checkVirglSupport(), false);
});

test('hasVirglDeviceMapping detects /dev/dri mappings', () => {
    assert.equal(hasVirglDeviceMapping(['/dev/dri/card0:/dev/dri/card0']), true);
    assert.equal(hasVirglDeviceMapping(['/dev/input/js0']), false);
});
