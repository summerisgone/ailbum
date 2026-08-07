const { app, BrowserWindow, dialog, ipcMain, nativeImage, protocol } = require("electron");
const { spawn } = require("node:child_process");
const { existsSync, writeFileSync } = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");

protocol.registerSchemesAsPrivileged([
  {
    scheme: "ailbum-media",
    privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true },
  },
]);

const projectRoot = path.resolve(__dirname, "../..");
let databasePath = path.resolve(
  process.env.AILBUM_DATABASE || path.join(projectRoot, ".ailbum/ailbum.sqlite3"),
);
let bridge;
const mediaPaths = new Map();
const thumbnailCache = new Map();
const THUMBNAIL_CACHE_LIMIT = 256;

function pythonExecutable() {
  if (process.env.AILBUM_PYTHON) return process.env.AILBUM_PYTHON;
  const candidates =
    process.platform === "win32"
      ? [path.join(projectRoot, ".venv/Scripts/python.exe"), "python"]
      : [path.join(projectRoot, ".venv/bin/python"), "python3"];
  return candidates.find((candidate) => !path.isAbsolute(candidate) || existsSync(candidate));
}

class PythonBridge {
  constructor(database) {
    this.nextId = 1;
    this.pending = new Map();
    this.process = spawn(
      pythonExecutable(),
      ["-m", "ailbum.desktop_bridge", "--database", database],
      { cwd: projectRoot, stdio: ["pipe", "pipe", "pipe"] },
    );
    const lines = readline.createInterface({ input: this.process.stdout });
    lines.on("line", (line) => this.handleLine(line));
    this.process.stderr.on("data", (chunk) => console.error(`[ailbum-python] ${chunk}`));
    this.process.on("error", (error) => this.rejectAll(error));
    this.process.on("exit", (code) =>
      this.rejectAll(new Error(`Python bridge stopped with exit code ${code}`)),
    );
  }

  handleLine(line) {
    let response;
    try {
      response = JSON.parse(line);
    } catch {
      console.error("Invalid Python bridge response", line);
      return;
    }
    const request = this.pending.get(response.id);
    if (!request) return;
    this.pending.delete(response.id);
    clearTimeout(request.timeout);
    if (response.error) request.reject(new Error(response.error));
    else request.resolve(response.result);
  }

  request(action, payload = {}) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Python bridge timed out: ${action}`));
      }, 20_000);
      this.pending.set(id, { resolve, reject, timeout });
      this.process.stdin.write(`${JSON.stringify({ id, action, payload })}\n`);
    });
  }

  rejectAll(error) {
    for (const request of this.pending.values()) {
      clearTimeout(request.timeout);
      request.reject(error);
    }
    this.pending.clear();
  }

  close() {
    if (!this.process.killed) this.process.kill();
  }
}

function startBridge() {
  bridge?.close();
  bridge = new PythonBridge(databasePath);
}

async function bootstrap() {
  if (!bridge) startBridge();
  const library = await bridge.request("library.bootstrap");
  mediaPaths.clear();
  thumbnailCache.clear();
  for (const photo of library.photos) mediaPaths.set(Number(photo.id), photo.path);
  return library;
}

async function thumbnailFor(imageId, photoPath) {
  let thumbnail = thumbnailCache.get(imageId);
  if (thumbnail) {
    thumbnailCache.delete(imageId);
    thumbnailCache.set(imageId, thumbnail);
    return thumbnail;
  }
  thumbnail = nativeImage
    .createThumbnailFromPath(photoPath, { width: 720, height: 480 })
    .catch(() => nativeImage.createFromPath(photoPath).resize({ width: 720, quality: "good" }))
    .then((image) => image.toJPEG(82));
  thumbnailCache.set(imageId, thumbnail);
  if (thumbnailCache.size > THUMBNAIL_CACHE_LIMIT) {
    thumbnailCache.delete(thumbnailCache.keys().next().value);
  }
  return thumbnail;
}

function createWindow() {
  const window = new BrowserWindow({
    width: 1480,
    height: 940,
    minWidth: 980,
    minHeight: 680,
    backgroundColor: "#f5f5f2",
    titleBarStyle: "hiddenInset",
    trafficLightPosition: { x: 18, y: 18 },
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  window.webContents.on("will-navigate", (event, url) => {
    const devUrl = process.env.AILBUM_RENDERER_URL;
    if (!devUrl || !url.startsWith(devUrl)) event.preventDefault();
  });
  if (process.env.AILBUM_RENDERER_URL) window.loadURL(process.env.AILBUM_RENDERER_URL);
  else window.loadFile(path.join(__dirname, "../dist/index.html"));

  if (process.env.AILBUM_SCREENSHOT) {
    window.webContents.once("did-finish-load", () => {
      setTimeout(async () => {
        const image = await window.webContents.capturePage();
        writeFileSync(path.resolve(process.env.AILBUM_SCREENSHOT), image.toPNG());
        app.quit();
      }, 5000);
    });
  }
}

app.whenReady().then(() => {
  startBridge();
  protocol.handle("ailbum-media", async (request) => {
    const url = new URL(request.url);
    const imageId = Number(url.pathname.slice(1));
    const photoPath = url.host === "photo" ? mediaPaths.get(imageId) : undefined;
    if (!photoPath || !existsSync(photoPath)) {
      return new Response("Photo not found", { status: 404 });
    }
    const bytes = await thumbnailFor(imageId, photoPath);
    return new Response(bytes, {
      headers: {
        "Content-Type": "image/jpeg",
        "Cache-Control": "public, max-age=3600",
      },
    });
  });

  ipcMain.handle("library:bootstrap", () => bootstrap());
  ipcMain.handle("favorite:set", (_event, { runId, imageId, favorite }) =>
    bridge.request("favorite.set", {
      run_id: String(runId),
      image_id: Number(imageId),
      favorite: Boolean(favorite),
    }),
  );
  ipcMain.handle("target:set", (_event, { runId, targetCount }) =>
    bridge.request("target.set", {
      run_id: String(runId),
      target_count: Number(targetCount),
    }),
  );
  ipcMain.handle("database:choose", async () => {
    const result = await dialog.showOpenDialog({
      title: "Выберите каталог Ailbum",
      properties: ["openFile"],
      filters: [{ name: "SQLite", extensions: ["sqlite3", "sqlite", "db"] }],
    });
    if (result.canceled || !result.filePaths[0]) return null;
    databasePath = path.resolve(result.filePaths[0]);
    startBridge();
    return bootstrap();
  });

  createWindow();
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("before-quit", () => bridge?.close());
app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
