const { contextBridge, ipcRenderer, webUtils } = require("electron");

contextBridge.exposeInMainWorld("ailbum", {
  platform: process.platform,
  bootstrap: () => ipcRenderer.invoke("library:bootstrap"),
  setFavorite: (runId, imageId, favorite) =>
    ipcRenderer.invoke("favorite:set", { runId, imageId, favorite }),
  setTarget: (runId, targetCount) =>
    ipcRenderer.invoke("target:set", { runId, targetCount }),
  getPeople: () => ipcRenderer.invoke("people:bootstrap"),
  getFaces: (personId) => ipcRenderer.invoke("person:faces", { personId }),
  setPersonName: (personId, name) =>
    ipcRenderer.invoke("person:name", { personId, name }),
  mergePerson: (sourceId, targetId) =>
    ipcRenderer.invoke("person:merge", { sourceId, targetId }),
  assignFace: (faceId, personId) =>
    ipcRenderer.invoke("face:assign", { faceId, personId }),
  createPersonFromFace: (faceId, name) =>
    ipcRenderer.invoke("face:create-person", { faceId, name }),
  chooseDatabase: () => ipcRenderer.invoke("database:choose"),
  createDatabase: () => ipcRenderer.invoke("database:create"),
  getDatabaseSummary: () => ipcRenderer.invoke("database:summary"),
  choosePhotoFolders: () => ipcRenderer.invoke("photos:choose-folders"),
  pathForFile: (file) => webUtils.getPathForFile(file),
  startDatabaseJob: (kind, sources = []) =>
    ipcRenderer.invoke("database:job-start", { kind, sources }),
  getDatabaseJob: () => ipcRenderer.invoke("database:job-status"),
  cancelDatabaseJob: () => ipcRenderer.invoke("database:job-cancel"),
  onDatabaseJob: (listener) => {
    const handler = (_event, update) => listener(update);
    ipcRenderer.on("database:job-progress", handler);
    return () => ipcRenderer.removeListener("database:job-progress", handler);
  },
  mediaUrl: (imageId) => `ailbum-media://photo/${imageId}`,
  originalUrl: (imageId) => `ailbum-media://original/${imageId}`,
  faceUrl: (faceId) => `ailbum-media://face/${faceId}`,
});
