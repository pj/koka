// An HTTP/2 server (Node's http2 module) for test/net/http6.kk: h2c and TLS
// (certificate and key in KK_CERT and KK_KEY) on free ports, printed as
// "ports <h2c> <tls>". It exits when its standard input is closed.
import http2 from 'node:http2';
function onRequest(req, res) {
  if (req.url === '/big') { res.end('z'.repeat(200000)); return; }
  if (req.url === '/echo') {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => { const b = Buffer.concat(chunks); res.setHeader('x-received', String(b.length)); res.end(b); });
    return;
  }
  res.setHeader('x-node', 'yes');
  res.end('node ' + req.httpVersion + ' ' + req.method + ' ' + req.url + ' ua=' + (req.headers['user-agent'] || '-'));
}
const plain = http2.createServer({}, onRequest);
const secure = http2.createSecureServer({ cert: process.env.KK_CERT, key: process.env.KK_KEY }, onRequest);
plain.listen(0, '127.0.0.1', () => {
  secure.listen(0, '127.0.0.1', () => console.log('ports ' + plain.address().port + ' ' + secure.address().port));
});
process.stdin.resume();
process.stdin.on('end', () => process.exit(0));
