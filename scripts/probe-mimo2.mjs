// Probe 2: confirm the token works on api.xiaomimimo.com at all, and find
// which routes the openresty front end actually exposes.
import https from 'https';

const token = process.env.ANTHROPIC_AUTH_TOKEN;
if (!token) {
  console.log('NO TOKEN IN ENV');
  process.exit(0);
}
const host = 'api.xiaomimimo.com';

// (method, path, body)
const probes = [
  ['GET', '/anthropic/v1/models', null],
  ['POST', '/anthropic/v1/messages', {
    model: 'claude-sonnet-4-5',
    max_tokens: 1,
    messages: [{ role: 'user', content: 'hi' }],
  }],
  ['GET', '/anthropic/api/monitor/usage/quota/limit', null],
  ['GET', '/api/monitor/usage/quota/limit', null],
  ['GET', '/anthropic/', null],
  ['GET', '/', null],
  ['GET', '/health', null],
  ['GET', '/anthropic/v1/me', null],
  ['GET', '/anthropic/v1/usage', null],
];

const call = (method, path, body) => new Promise((resolve) => {
  const payload = body ? JSON.stringify(body) : null;
  const headers = {
    Authorization: `Bearer ${token}`,
    'x-api-key': token,
    'anthropic-version': '2023-06-01',
    Accept: 'application/json',
  };
  if (payload) {
    headers['Content-Type'] = 'application/json';
    headers['Content-Length'] = Buffer.byteLength(payload);
  }
  const req = https.request({ hostname: host, port: 443, path, method, headers }, (res) => {
    let buf = '';
    res.on('data', (c) => {
      buf += c;
      if (buf.length > 700) buf = buf.slice(0, 700);
    });
    res.on('end', () => resolve({ method, path, status: res.statusCode, body: buf }));
  });
  req.on('error', (e) => resolve({ method, path, status: 'ERR', body: String(e) }));
  req.setTimeout(20000, () => {
    req.destroy();
    resolve({ method, path, status: 'TIMEOUT', body: '' });
  });
  if (payload) req.write(payload);
  req.end();
});

for (const [m, p, b] of probes) {
  const r = await call(m, p, b);
  const isHtml = r.body.includes('<html');
  console.log(`=== ${r.method} ${r.path} -> HTTP ${r.status}${isHtml ? ' (html/404)' : ''} ===`);
  if (!isHtml) console.log(r.body);
  console.log('');
}
