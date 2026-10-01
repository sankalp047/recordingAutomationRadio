// Proves net.request only sends session cookies when useSessionCookies is set.
// This is the bug that made the Windows sign-in loop: the login worked, the
// cookie was stored, and every API call afterwards omitted it.
const { app, session, net } = require('electron');
const http = require('node:http');

const server = http.createServer((req, res) => {
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify({ cookie: req.headers.cookie || null }));
});

function call(url, opts) {
  return new Promise((resolve, reject) => {
    const r = net.request({ url, session: session.defaultSession, ...opts });
    const chunks = [];
    r.on('response', (res) => {
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve(JSON.parse(Buffer.concat(chunks).toString())));
    });
    r.on('error', reject);
    r.end();
  });
}

app.whenReady().then(async () => {
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;

  await session.defaultSession.cookies.set({
    url: base, name: 'CF_Authorization', value: 'test-token-value',
  });

  const without = await call(base + '/', {});
  const with_ = await call(base + '/', { useSessionCookies: true, credentials: 'include' });

  let fails = 0;
  const check = (name, cond, detail) => {
    if (!cond) fails++;
    console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
  };

  check('default net.request sends NO cookie (the bug)',
        without.cookie === null, `server saw: ${without.cookie}`);
  check('useSessionCookies:true DOES send the cookie (the fix)',
        with_.cookie && with_.cookie.includes('CF_Authorization=test-token-value'),
        `server saw: ${with_.cookie}`);

  server.close();
  app.exit(fails ? 1 : 0);
});
