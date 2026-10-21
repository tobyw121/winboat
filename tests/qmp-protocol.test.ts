import {test} from 'node:test';import assert from 'node:assert/strict';import {EventEmitter} from 'node:events';import type {Socket} from 'node:net';
import {QMPTransport} from '../src/shared/qmp-protocol';
class Peer extends EventEmitter{sent:any[]=[];write(value:string,callback:(e?:Error)=>void){this.sent.push(JSON.parse(value));callback();return true;}destroy(){this.emit('close');}}
test('QMP frames split greetings, interleaved events and reversed concurrent replies',async()=>{
 const peer=new Peer(),client=new QMPTransport(peer as unknown as Socket);peer.emit('data',Buffer.from('{"QMP":'));peer.emit('data',Buffer.from('{}}\r\n'));await client.greeting;
 const a=client.request('query-status'),b=client.request('query-block');
 peer.emit('data',Buffer.from(JSON.stringify({event:'DEVICE_DELETED'})+'\n'+JSON.stringify({id:peer.sent[1].id,return:['disk']})+'\n'));
 peer.emit('data',Buffer.from(JSON.stringify({id:peer.sent[0].id,return:{status:'running'}})+'\n'));
 assert.deepEqual(await b,{id:'2',return:['disk']});assert.deepEqual(await a,{id:'1',return:{status:'running'}});peer.destroy();
});
test('QMP closure rejects pending commands instead of leaving a USB operation hung',async()=>{
 const peer=new Peer(),client=new QMPTransport(peer as unknown as Socket);peer.emit('data',Buffer.from('{"QMP":{}}\n'));await client.greeting;
 const waiting=assert.rejects(client.request('device_del'),/closed/);peer.destroy();await waiting;
});
