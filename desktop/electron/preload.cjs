const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("ailbum", {
  bootstrap: () => ipcRenderer.invoke("library:bootstrap"),
  setFavorite: (runId, imageId, favorite) =>
    ipcRenderer.invoke("favorite:set", { runId, imageId, favorite }),
  setTarget: (runId, targetCount) =>
    ipcRenderer.invoke("target:set", { runId, targetCount }),
  chooseDatabase: () => ipcRenderer.invoke("database:choose"),
  mediaUrl: (imageId) => `ailbum-media://photo/${imageId}`,
});
