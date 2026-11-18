// A WebSocket client (Node's built-in WebSocket) for test/net/websocket2.kk:
// talks to the echo server at argv[2] (ws) and argv[3] (wss, CA in NODE_EXTRA_CA_CERTS).
function open(url, protocols) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, protocols);
    ws.binaryType = 'arraybuffer';
    const queue = []; const waiting = [];
    ws.onmessage = (e) => { if (waiting.length) waiting.shift()(e.data); else queue.push(e.data); };
    ws.onopen = () => resolve({ ws, next: () => queue.length ? Promise.resolve(queue.shift()) : new Promise((r) => waiting.push(r)) });
    ws.onerror = (e) => reject(new Error('websocket error ' + url));
  });
}
function show(d) { return typeof d === 'string' ? (d.length > 40 ? 'text ' + d.length : 'text ' + d) : 'binary ' + d.byteLength; }
async function run(name, url) {
  const { ws, next } = await open(url, ['chat']);
  console.log(name, 'protocol', ws.protocol);
  ws.send('hello');
  console.log(name, show(await next()));
  ws.send(new Uint8Array([1, 2, 3]));
  console.log(name, show(await next()));
  ws.send('ü'.repeat(100000));
  const big = await next();
  console.log(name, show(big), big === 'ü'.repeat(100000));
  ws.send(new Uint8Array(70000).fill(7));
  console.log(name, show(await next()));
  const closed = new Promise((r) => { ws.onclose = (e) => r(e); });
  ws.close(4001, 'done');
  const e = await closed;
  console.log(name, 'closed', e.code, e.reason, e.wasClean);
}
await run('ws', 'ws://127.0.0.1:' + process.argv[2] + '/echo');
await run('wss', 'wss://localhost:' + process.argv[3] + '/echo');
// the server closes first
const { ws, next } = await open('ws://127.0.0.1:' + process.argv[2] + '/bye', []);
const closed = new Promise((r) => { ws.onclose = (e) => r(e); });
console.log('bye', show(await next()));
const e = await closed;
console.log('bye closed', e.code, e.reason, e.wasClean);
