import { test } from 'node:test';
import assert from 'node:assert/strict';
import { satisfiesPrequisites, defaultSpecs } from '../src/shared/prerequisites';
test('Local Desktop and browser installation do not require FreeRDP', () => {
    const specs = {...defaultSpecs, cpuCores: 2, ramGB: 4, kvmEnabled: true,
        dockerInstalled: true, dockerComposeInstalled: true, dockerIsRunning: true, dockerIsInUserGroups: true};
    assert.equal(satisfiesPrequisites(specs), true);
    assert.equal(satisfiesPrequisites({...specs, freeRDP3Installed: true}), true);
    assert.equal(satisfiesPrequisites({...specs, kvmEnabled: false}), false);
    assert.equal(satisfiesPrequisites({...specs, dockerIsRunning: false}), false);
});
