const { app, BrowserWindow, Tray, Menu, ipcMain, shell, screen, dialog } = require('electron');
const path = require('path');
const fs = require('fs');

let orbWindow;
let hubWindow;
let tray;

function makeWindow(options) {
  return new BrowserWindow({
    frame: false, transparent: true, resizable: false, show: false,
    alwaysOnTop: true, skipTaskbar: true, backgroundColor: '#00000000',
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false },
    ...options
  });
}

function showHub() {
  if (!hubWindow || hubWindow.isDestroyed()) {
    hubWindow = new BrowserWindow({ width: 900, height: 620, minWidth: 760, minHeight: 520,
      title: 'My Hub', backgroundColor: '#11161c', webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false } });
    hubWindow.loadFile(path.join(__dirname, 'index.html'));
    hubWindow.on('closed', () => { hubWindow = null; });
  }
  hubWindow.show(); hubWindow.focus();
}

function showOrb() {
  const display = screen.getPrimaryDisplay().workArea;
  if (!orbWindow || orbWindow.isDestroyed()) {
    orbWindow = makeWindow({ width: 76, height: 76, x: display.x + display.width - 100, y: display.y + display.height / 2 - 38 });
    orbWindow.loadFile(path.join(__dirname, 'orb.html'));
    orbWindow.showInactive();
  }
}

function installedApps() {
  const roots = [process.env.APPDATA && path.join(process.env.APPDATA, 'Microsoft', 'Windows', 'Start Menu', 'Programs'),
    process.env.ProgramData && path.join(process.env.ProgramData, 'Microsoft', 'Windows', 'Start Menu', 'Programs'),
    process.env.USERPROFILE && path.join(process.env.USERPROFILE, 'Desktop')].filter(Boolean);
  const found = [];
  const scan = dir => { if (!fs.existsSync(dir)) return; for (const item of fs.readdirSync(dir, { withFileTypes: true })) { const full = path.join(dir, item.name); if (item.isDirectory()) scan(full); else if (/\.(lnk|exe)$/i.test(item.name)) found.push({ name: item.name.replace(/\.(lnk|exe)$/i, ''), path: full }); } };
  roots.forEach(scan);
  return found.slice(0, 120);
}

app.whenReady().then(() => {
  ipcMain.handle('open-hub', showHub);
  ipcMain.handle('open-path', (_, target) => shell.openPath(target));
  ipcMain.handle('apps', installedApps);
  ipcMain.handle('pick-app', async () => {
    const result = await dialog.showOpenDialog({ properties: ['openFile'], filters: [{ name: 'Windows Apps', extensions: ['exe', 'lnk'] }] });
    return result.canceled ? null : result.filePaths[0];
  });
  ipcMain.handle('quit', () => app.quit());
  tray = new Tray(path.join(__dirname, 'tray.png'));
  tray.setToolTip('My Hub');
  tray.setContextMenu(Menu.buildFromTemplate([{ label: 'My Hub öffnen', click: showHub }, { label: 'Radmenü anzeigen', click: showOrb }, { type: 'separator' }, { label: 'Beenden', click: () => app.quit() }]));
  showOrb();
});

app.on('window-all-closed', event => event.preventDefault());
