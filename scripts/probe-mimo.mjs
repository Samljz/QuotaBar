// Ad-hoc probe: discover which quota/usage endpoints api.xiaomimimo.com exposes.
// Uses the ANTHROPIC_AUTH_TOKEN already in the environment (user authorized this).
// Never prints the token.
import https from 'https';

const token = process.env.ANTHROPIC_AUTH_TOKEN;
if (!token) {
  console.log('NO TOKEN IN ENV');
  process.exit(0);
}

const host = 'api.xiaomimimo.com';
const paths = [
  '/anthropic/api/monitor/usage/quota/limit',
  '/anthropic/v1/models',
  '/api/usage/quota',
  '/api/usage/limit',
  '/api/user/quota',
  '/api/account/usage',
  '/v1/usage',
  '/api/monitor/quota',
  '/api/anthropic/api/monitor/usage/quota/limit',
];

const get = (path) => new Promise((resolve) => {
  const req = https.request({
    hostname: host,
    port: 443,
    path,
    method: 'GET',
    headers: { Authorization: token, 'x-api-key': token, Accept: 'application/json' },
  }, (res) => {
    let body = '';
    res.on('data', (c) => {
      body += c;
      if (body.length > 500) body = body.slice(0, 500);
    });
    res.on('end', () => resolve({ path, status: res.statusCode, body }));
  });
  req.on('error', (e) => resolve({ path, status: 'ERR', body: String(e) }));
  req.setTimeout(15000, () => {
    req.destroy();
    resolve({ path, status: 'TIMEOUT', body: '' });
  });
  req.end();
});

for (const p of paths) {
  const r = await get(p);
  const isHtml = r.body.includes('<html');
  console.log(`=== ${r.path} -> HTTP ${r.status}${isHtml ? ' (html/404)' : ''} ===`);
  if (!isHtml) console.log(r.body);
  console.log('');
}
