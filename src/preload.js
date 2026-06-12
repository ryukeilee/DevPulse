const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('devPulse', {
  getState: () => ipcRenderer.invoke('devpulse:get-state'),
  onStateChanged: (callback) => {
    const listener = (_event, state) => callback(state);
    ipcRenderer.on('devpulse:state-changed', listener);
    return () => ipcRenderer.removeListener('devpulse:state-changed', listener);
  }
});
