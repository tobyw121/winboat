import {test} from 'node:test';
import assert from 'node:assert/strict';
import {ClipboardEchoGuard,validClipboardText} from '../src/shared/clipboard-sync';
test('clipboard forwards new text without reflecting an imported value or its own echo',()=>{
 const guard=new ClipboardEchoGuard('initial-private-value','host-id');
 assert.equal(guard.localChange('initial-private-value'),undefined);
 assert.equal(guard.remoteChange({revision:1,text:'guest text'}),'guest text');
 assert.equal(guard.localChange('guest text'),undefined);
 assert.deepEqual(guard.localChange('new host text'),{kind:'write',text:'new host text',origin:'host-id'});
 assert.equal(guard.remoteChange({revision:2,text:'new host text',origin:'host-id'}),undefined);
 assert.equal(guard.remoteChange({revision:1,text:'stale'}),undefined);
});
test('plain text byte limits account for multibyte text and prohibit NUL',()=>{
 assert.equal(validClipboardText('ä'.repeat(131072)),true);
 assert.equal(validClipboardText('ä'.repeat(131073)),false);
 assert.equal(validClipboardText('bad\0text'),false);
});
