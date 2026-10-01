'use strict';
const { app, BrowserWindow, ipcMain, dialog, shell, session, net } = require('electron');
const path = require('node:path');
const fs = require('node:fs');

const DEFAULT_API = 'https://radio-api.funasia.net';
let win = null;

function createWindow() {
  win = new BrowserWindow({
    width: 1180,
    height: 760,
    minWidth: 900,
    minHeight: 600,
    title: 'PM Radio Logs',
    backgroundColor: '#f6f7f9',
    icon: path.join(__dirname, '..', 'build', 'icon.png'),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  win.setMenuBarVisibility(false);
  win.loadFile(path.join(__dirname, 'index.html'));
  win.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: 'deny' };
  });
}

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });

/** Requests share the app session, so the Cloudflare Access cookie is sent. */
function request(url, { method = 'GET', headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const r = net.request({ method, url, session: session.defaultSession, redirect: 'follow' });
    for (const [k, v] of Object.entries(headers)) r.setHeader(k, v);
    const chunks = [];
    r.on('response', (res) => {
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({
        status: res.statusCode,
        headers: res.headers,
        finalURL: res.headers.location || url,
        body: Buffer.concat(chunks),
      }));
      res.on('error', reject);
    });
    r.on('error', reject);
    r.end();
  });
}

ipcMain.handle('api:get', async (_e, { base, pathname, query }) => {
  const url = new URL(pathname, base);
  for (const [k, v] of Object.entries(query || {})) {
    if (v !== undefined && v !== null && v !== '') url.searchParams.set(k, v);
  }
  let res;
  try {
    res = await request(url.toString());
  } catch (e) {
    return { ok: false, kind: 'transport', message: e.message };
  }
  const ctype = String(res.headers['content-type'] || '');
  // Cloudflare Access answers an unauthenticated request with its own HTML
  // login page, so HTML here means "sign in", not "bad request".
  if (ctype.includes('text/html')) {
    return { ok: false, kind: 'signin', message: 'Sign in with your funasia.net account.' };
  }
  if (res.status === 401) {
    return { ok: false, kind: 'signin', message: 'Sign in with your funasia.net account.' };
  }
  if (res.status < 200 || res.status >= 300) {
    return { ok: false, kind: 'http', status: res.status, message: `Server error ${res.status}` };
  }
  try {
    return { ok: true, data: JSON.parse(res.body.toString('utf8')) };
  } catch {
    return { ok: false, kind: 'parse', message: 'Could not read the response.' };
  }
});

/** Opens the Access login in a real window; Access sets its cookie on the
 *  shared session, so ordinary requests work afterwards. */
ipcMain.handle('auth:signIn', async (_e, base) => {
  return new Promise((resolve) => {
    const w = new BrowserWindow({
      width: 560, height: 680, parent: win, modal: true, title: 'Sign in',
      webPreferences: { contextIsolation: true, nodeIntegration: false },
    });
    w.setMenuBarVisibility(false);
    let settled = false;
    const finish = (ok) => {
      if (settled) return;
      settled = true;
      resolve({ ok });
      if (!w.isDestroyed()) w.close();
    };
    w.webContents.on('did-navigate', (_ev, url) => {
      try {
        const h = new URL(url).hostname;
        // back on our own host means Access let the request through
        if (h === new URL(base).hostname) finish(true);
      } catch {}
    });
    w.on('closed', () => { if (!settled) { settled = true; resolve({ ok: false }); } });
    w.loadURL(new URL('/health', base).toString());
  });
});

ipcMain.handle('auth:signOut', async (_e, base) => {
  const host = new URL(base).hostname;
  const cookies = await session.defaultSession.cookies.get({});
  for (const c of cookies) {
    if (c.domain && (host.endsWith(c.domain.replace(/^\./, '')) || c.domain.includes('cloudflareaccess'))) {
      const u = `http${c.secure ? 's' : ''}://${c.domain.replace(/^\./, '')}${c.path}`;
      try { await session.defaultSession.cookies.remove(u, c.name); } catch {}
    }
  }
  return { ok: true };
});

ipcMain.handle('file:saveOne', async (_e, { url, suggested }) => {
  const { canceled, filePath } = await dialog.showSaveDialog(win, {
    defaultPath: suggested,
    filters: [{ name: 'Audio', extensions: ['mp3'] }],
  });
  if (canceled || !filePath) return { ok: false, canceled: true };
  try {
    const res = await request(url);
    if (res.status < 200 || res.status >= 300) {
      return { ok: false, message: `Server returned ${res.status}` };
    }
    fs.writeFileSync(filePath, res.body);
    shell.showItemInFolder(filePath);
    return { ok: true, path: filePath };
  } catch (e) {
    return { ok: false, message: e.message };
  }
});

ipcMain.handle('file:saveMany', async (_e, { items, folderName }) => {
  const { canceled, filePaths } = await dialog.showOpenDialog(win, {
    properties: ['openDirectory', 'createDirectory'],
    buttonLabel: 'Save here',
  });
  if (canceled || !filePaths?.length) return { ok: false, canceled: true };
  const dir = path.join(filePaths[0], folderName);
  fs.mkdirSync(dir, { recursive: true });
  let saved = 0, failed = 0;
  for (const it of items) {
    try {
      const res = await request(it.url);
      if (res.status >= 200 && res.status < 300) {
        fs.writeFileSync(path.join(dir, it.name), res.body);
        saved++;
      } else failed++;
      win?.webContents.send('save:progress', { done: saved + failed, total: items.length });
    } catch { failed++; }
  }
  shell.openPath(dir);
  return { ok: true, saved, failed, dir };
});

ipcMain.handle('app:defaults', () => ({ api: process.env.RADIO_API || DEFAULT_API }));
