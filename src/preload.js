const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('devPulse', {
  getState: () => ipcRenderer.invoke('devpulse:get-state'),
  getConfig: () => ipcRenderer.invoke('devpulse:get-config'),
  updateSettings: (settings) => ipcRenderer.invoke('devpulse:update-settings', settings),
  onStateChanged: (callback) => {
    const listener = (_event, state) => callback(state);
    ipcRenderer.on('devpulse:state-changed', listener);
    return () => ipcRenderer.removeListener('devpulse:state-changed', listener);
  },
  onConfigChanged: (callback) => {
    const listener = (_event, config) => callback(config);
    ipcRenderer.on('devpulse:config-changed', listener);
    return () => ipcRenderer.removeListener('devpulse:config-changed', listener);
  }
});

contextBridge.exposeInMainWorld('desktopWidget', {
  quitApp: () => ipcRenderer.invoke('app:quit')
});

contextBridge.exposeInMainWorld('floatingWindow', {
  getState: () => ipcRenderer.invoke('floating:get-state'),
  toggleAlwaysOnTop: () => ipcRenderer.invoke('floating:toggle-always-on-top'),
  toggleCollapse: () => ipcRenderer.invoke('floating:toggle-collapse'),
  setDisplayMode: (displayMode) => ipcRenderer.invoke('floating:set-display-mode', displayMode),
  hide: () => ipcRenderer.invoke('floating:hide'),
  show: () => ipcRenderer.invoke('floating:show'),
  onStateChanged: (callback) => {
    const listener = (_event, state) => callback(state);
    ipcRenderer.on('floating:state-changed', listener);
    return () => ipcRenderer.removeListener('floating:state-changed', listener);
  },
  onCollapsedChanged: (callback) => {
    const listener = (_event, collapsed) => callback(collapsed);
    ipcRenderer.on('floating:collapsed-changed', listener);
    return () => ipcRenderer.removeListener('floating:collapsed-changed', listener);
  }
});
