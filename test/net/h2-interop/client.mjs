// An HTTP/2 client (Node's http2 module) for test/net/http6.kk: requests to
// an h2c server on port argv[2] and a TLS server on port argv[3] (CA in KK_CA).
import http2 from 'node:http2';
function request(session, method, path, body) {
  return new Promise((resolve, reject) => {
    const req = session.request({ ':method': method, ':path': path });
    let status = 0; const chunks = [];
    req.on('response', (h) => { status = h[':status']; });
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve([status, Buffer.concat(chunks)]));
    req.on('error', reject);
    if (body) req.end(body); else req.end();
  });
}
async function run(name, url, opts) {
  const session = http2.connect(url, opts);
  const [s1, b1] = await request(session, 'GET', '/hello');
  console.log(name, s1, b1.toString().trim());
  const [s2, b2] = await request(session, 'GET', '/big');
  console.log(name, s2, 'big', b2.length);
  const [s3, b3] = await request(session, 'POST', '/echo', Buffer.alloc(300000, 'e'));
  console.log(name, s3, 'echo', b3.length);
  const many = await Promise.all([...Array(20).keys()].map((i) => request(session, 'GET', '/m' + i)));
  console.log(name, 'parallel', many.filter(([s, b]) => s === 200 && b.toString().includes('/m')).length);
  const bigs = await Promise.all([1, 2, 3].map(() => request(session, 'GET', '/big')));
  console.log(name, 'parallel big', bigs.map(([s, b]) => b.length).join(','));
  session.close();
}
await run('h2c', 'http://127.0.0.1:' + process.argv[2], {});
await run('tls', 'https://localhost:' + process.argv[3], { ca: process.env.KK_CA });
