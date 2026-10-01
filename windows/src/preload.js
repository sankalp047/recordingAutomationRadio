'use strict';
const { contextBridge, ipcRenderer } = require('electron');

// The renderer gets a narrow, named surface rather than node APIs.
contextBridge.exposeInMainWorld('api', {
  get: (base, pathname, query) => ipcRenderer.invoke('api:get', { base, pathname, query }),
  signIn: (base) => ipcRenderer.invoke('auth:signIn', base),
  signOut: (base) => ipcRenderer.invoke('auth:signOut', base),
  saveOne: (url, suggested) => ipcRenderer.invoke('file:saveOne', { url, suggested }),
  saveMany: (items, folderName) => ipcRenderer.invoke('file:saveMany', { items, folderName }),
  defaults: () => ipcRenderer.invoke('app:defaults'),
  onSaveProgress: (cb) => ipcRenderer.on('save:progress', (_e, d) => cb(d)),
});
