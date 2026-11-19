const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('myHub', {
  openHub: () => ipcRenderer.invoke('open-hub'),
  openPath: path => ipcRenderer.invoke('open-path', path),
  installedApps: () => ipcRenderer.invoke('apps'),
  pickApp: () => ipcRenderer.invoke('pick-app'),
  quit: () => ipcRenderer.invoke('quit')
});
