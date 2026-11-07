const { app, BrowserWindow, dialog, ipcMain, nativeImage, net, protocol } = require("electron");
const { spawn } = require("node:child_process");
const { existsSync, writeFileSync } = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");
const { pathToFileURL } = require("node:url");

protocol.registerSchemesAsPrivileged([
  {
    scheme: "ailbum-media",
    privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true },
  },
]);

const projectRoot = path.resolve(__dirname, "../..");
let databasePath;
let bridge;
let mainWindow;
let activeJob;
let jobState = { status: "idle" };
const mediaPaths = new Map();
const faceMedia = new Map();
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

function initializeRuntimePaths() {
  const defaultDatabase = app.isPackaged
    ? path.join(app.getPath("userData"), "ailbum.sqlite3")
    : path.join(projectRoot, ".ailbum/ailbum.sqlite3");
  databasePath = path.resolve(process.env.AILBUM_DATABASE || defaultDatabase);
}

function backendInvocation(mode, moduleName, args) {
  if (app.isPackaged) {
    const executable = path.join(
      process.resourcesPath,
      "backend",
      process.platform === "win32" ? "ailbum-backend.exe" : "ailbum-backend",
    );
    return {
      executable,
      args: [mode, ...args],
      cwd: app.getPath("userData"),
    };
  }
  return {
    executable: pythonExecutable(),
    args: ["-m", moduleName, ...args],
    cwd: projectRoot,
  };
}

function runtimeModelsPath() {
  if (process.env.AILBUM_MODELS_DIR) return path.resolve(process.env.AILBUM_MODELS_DIR);
  return app.isPackaged
    ? path.join(process.resourcesPath, "models")
    : path.join(projectRoot, "models");
}

class PythonBridge {
  constructor(database) {
    this.nextId = 1;
    this.pending = new Map();
    const invocation = backendInvocation(
      "bridge",
      "ailbum.desktop_bridge",
      ["--database", database],
    );
    this.process = spawn(
      invocation.executable,
      invocation.args,
      { cwd: invocation.cwd, stdio: ["pipe", "pipe", "pipe"], windowsHide: true },
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
  if (!existsSync(databasePath)) await bridge.request("database.initialize");
  const library = await bridge.request("library.bootstrap");
  mediaPaths.clear();
  faceMedia.clear();
  thumbnailCache.clear();
  for (const photo of library.photos) mediaPaths.set(Number(photo.id), photo.path);
  return library;
}

function registerFaceMedia(result) {
  for (const face of result.faces || []) {
    faceMedia.set(Number(face.id), {
      path: face.path,
      x: Number(face.bbox_x),
      y: Number(face.bbox_y),
      width: Number(face.bbox_width),
      height: Number(face.bbox_height),
      orientation: Number(face.orientation || 1),
    });
  }
  return result;
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

async function faceThumbnailFor(faceId, face) {
  const cacheKey = `face-${faceId}`;
  let thumbnail = thumbnailCache.get(cacheKey);
  if (thumbnail) {
    thumbnailCache.delete(cacheKey);
    thumbnailCache.set(cacheKey, thumbnail);
    return thumbnail;
  }
  thumbnail = bridge
    .request("face.thumbnail", { face_id: faceId })
    .then((result) => Buffer.from(result.base64, "base64"));
  thumbnailCache.set(cacheKey, thumbnail);
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
  mainWindow = window;
  window.on("closed", () => {
    if (mainWindow === window) mainWindow = undefined;
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
        if (process.env.AILBUM_SCREENSHOT_PHOTO) {
          await window.webContents.executeJavaScript(`(() => {
            const input = document.querySelector('.search-box input');
            const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
            setter.call(input, ${JSON.stringify(process.env.AILBUM_SCREENSHOT_PHOTO)});
            input.dispatchEvent(new Event('input', { bubbles: true }));
          })()`);
          await new Promise((resolve) => setTimeout(resolve, 1200));
        }
        if (process.env.AILBUM_SCREENSHOT_SECTION === "people") {
          await window.webContents.executeJavaScript(
            'document.querySelector("[data-section=people]")?.click()',
          );
          await new Promise((resolve) => setTimeout(resolve, 2500));
        } else if (process.env.AILBUM_SCREENSHOT_SECTION === "settings") {
          await window.webContents.executeJavaScript(
            'document.querySelector(".sidebar-bottom")?.click()',
          );
          await new Promise((resolve) => setTimeout(resolve, 1200));
        } else if (process.env.AILBUM_SCREENSHOT_SECTION === "viewer") {
          await window.webContents.executeJavaScript(
            'document.querySelector(".photo-card")?.click()',
          );
          await new Promise((resolve) => setTimeout(resolve, 2000));
        } else if (process.env.AILBUM_SCREENSHOT_SECTION === "story-jump") {
          await window.webContents.executeJavaScript(
            'Array.from(document.querySelectorAll(".thumb-jump")).at(-1)?.click()',
          );
          await new Promise((resolve) => setTimeout(resolve, 1800));
        } else if (process.env.AILBUM_SCREENSHOT_SECTION === "series") {
          await window.webContents.executeJavaScript(
            'document.querySelector(".photo-card.stacked")?.click()',
          );
          await new Promise((resolve) => setTimeout(resolve, 1200));
        }
        const image = await window.webContents.capturePage();
        writeFileSync(path.resolve(process.env.AILBUM_SCREENSHOT), image.toPNG());
        app.quit();
      }, 5000);
    });
  }
}

function publishJob(update) {
  jobState = { ...jobState, ...update };
  mainWindow?.webContents.send("database:job-progress", jobState);
}

function startDatabaseJob(kind, sources = [], layout) {
  if (activeJob) throw new Error("Уже выполняется добавление или анализ фотографий");
  const args = [kind, "--database", databasePath, "--models-dir", runtimeModelsPath()];
  for (const source of sources) args.push("--source", path.resolve(source));
  if (kind === "layout") args.push("--run-id", layout.runId, "--params", JSON.stringify(layout.params));
  const invocation = backendInvocation("job", "ailbum.desktop_job", args);
  const process = spawn(invocation.executable, invocation.args, {
    cwd: invocation.cwd,
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  });
  activeJob = process;
  let reportedError;
  let stderr = "";
  publishJob({
    status: "running",
    kind,
    stage:
      kind === "index"
        ? "Подготовка добавления"
        : kind === "layout"
          ? "Подготовка раскладки"
          : "Подготовка анализа",
    detail: "",
    current: null,
    total: null,
    error: null,
  });
  const lines = readline.createInterface({ input: process.stdout });
  lines.on("line", (line) => {
    try {
      const update = JSON.parse(line);
      if (update.type === "progress") {
        publishJob({
          status: "running",
          stage: update.stage,
          detail: update.detail || "",
          current: update.current ?? null,
          total: update.total ?? null,
        });
      } else if (update.type === "error") {
        reportedError = update.error;
      } else if (update.type === "complete") {
        publishJob({ status: "complete", result: update.result, current: null, total: null });
      }
    } catch {
      publishJob({ status: "running", detail: line });
    }
  });
  process.stderr.on("data", (chunk) => {
    stderr = `${stderr}${chunk}`.slice(-4000);
    console.error(`[ailbum-job] ${chunk}`);
  });
  process.on("error", (error) => {
    if (activeJob === process) activeJob = undefined;
    publishJob({ status: "error", error: error.message });
  });
  process.on("exit", (code) => {
    if (activeJob === process) activeJob = undefined;
    if (process.ailbumCancelled) return;
    if (code !== 0) {
      const fallback = stderr.trim().split("\n").at(-1);
      publishJob({
        status: "error",
        error: reportedError || fallback || `Фоновый процесс завершился с кодом ${code}`,
      });
    } else if (jobState.status !== "complete") {
      publishJob({ status: "complete", current: null, total: null });
    }
  });
  return jobState;
}

app.whenReady().then(() => {
  initializeRuntimePaths();
  startBridge();
  if (process.env.AILBUM_SCREENSHOT_JOB) {
    jobState = {
      status: "running",
      kind: "analyze",
      stage: "Анализ фотографий",
      detail: "20260728_204955.jpg",
      current: 68,
      total: 144,
      error: null,
    };
  }
  protocol.handle("ailbum-media", async (request) => {
    const url = new URL(request.url);
    const imageId = Number(url.pathname.slice(1));
    if (url.host === "face") {
      const face = faceMedia.get(imageId);
      if (!face || !existsSync(face.path)) {
        return new Response("Face not found", { status: 404 });
      }
      const bytes = await faceThumbnailFor(imageId, face);
      return new Response(bytes, {
        headers: { "Content-Type": "image/jpeg", "Cache-Control": "public, max-age=3600" },
      });
    }
    if (url.host === "original") {
      const photoPath = mediaPaths.get(imageId);
      if (!photoPath || !existsSync(photoPath)) {
        return new Response("Photo not found", { status: 404 });
      }
      return net.fetch(pathToFileURL(photoPath).toString());
    }
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
  ipcMain.handle("database:summary", () => bridge.request("database.summary"));
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
  ipcMain.handle("people:bootstrap", () => bridge.request("people.bootstrap"));
  ipcMain.handle("person:faces", async (_event, { personId }) =>
    registerFaceMedia(
      await bridge.request("person.faces", {
        person_id: personId == null ? null : Number(personId),
      }),
    ),
  );
  ipcMain.handle("person:name", (_event, { personId, name }) =>
    bridge.request("person.name", { person_id: Number(personId), name: String(name || "") }),
  );
  ipcMain.handle("person:merge", (_event, { sourceId, targetId }) =>
    bridge.request("person.merge", {
      source_id: Number(sourceId),
      target_id: Number(targetId),
    }),
  );
  ipcMain.handle("face:assign", (_event, { faceId, personId }) =>
    bridge.request("face.assign", {
      face_id: Number(faceId),
      person_id: personId == null ? null : Number(personId),
    }),
  );
  ipcMain.handle("face:create-person", (_event, { faceId, name }) =>
    bridge.request("face.create_person", {
      face_id: Number(faceId),
      name: String(name || ""),
    }),
  );
  ipcMain.handle("database:choose", async () => {
    if (activeJob) throw new Error("Дождитесь завершения текущей операции");
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
  ipcMain.handle("database:create", async () => {
    if (activeJob) throw new Error("Дождитесь завершения текущей операции");
    const result = await dialog.showSaveDialog({
      title: "Создать базу Ailbum",
      defaultPath: "ailbum.sqlite3",
      filters: [{ name: "SQLite", extensions: ["sqlite3", "sqlite", "db"] }],
    });
    if (result.canceled || !result.filePath) return null;
    databasePath = path.resolve(result.filePath);
    startBridge();
    await bridge.request("database.initialize");
    return bootstrap();
  });
  ipcMain.handle("photos:choose-folders", async () => {
    const result = await dialog.showOpenDialog({
      title: "Выберите папки с фотографиями",
      properties: ["openDirectory", "multiSelections"],
    });
    return result.canceled ? [] : result.filePaths.map((item) => path.resolve(item));
  });
  ipcMain.handle("database:job-start", (_event, { kind, sources }) => {
    if (!['index', 'analyze'].includes(kind)) throw new Error("Неизвестный тип операции");
    return startDatabaseJob(kind, Array.isArray(sources) ? sources : []);
  });
  ipcMain.handle("layout:start", (_event, { runId, params }) =>
    startDatabaseJob("layout", [], { runId: String(runId), params: params || {} }),
  );
  ipcMain.handle("layout:preflight", (_event, { runId, params }) =>
    bridge.request("layout.preflight", { run_id: String(runId), ...params }),
  );
  ipcMain.handle("layout:get", (_event, { runId }) =>
    bridge.request("layout.get", { run_id: String(runId) }),
  );
  ipcMain.handle("layout:templates", (_event, { orientation, photoCount }) =>
    bridge.request("layout.templates", { orientation, photo_count: Number(photoCount) }),
  );
  ipcMain.handle("layout:alternatives", (_event, { spreadId, cellIndex }) =>
    bridge.request("layout.alternatives", {
      spread_id: Number(spreadId),
      cell_index: Number(cellIndex),
    }),
  );
  ipcMain.handle("layout:set-photo", (_event, { spreadId, cellIndex, imageId }) =>
    bridge.request("layout.set_photo", {
      spread_id: Number(spreadId),
      cell_index: Number(cellIndex),
      image_id: Number(imageId),
    }),
  );
  ipcMain.handle("layout:swap-cells", (_event, { spreadId, cellA, cellB }) =>
    bridge.request("layout.swap_cells", {
      spread_id: Number(spreadId),
      cell_a: Number(cellA),
      cell_b: Number(cellB),
    }),
  );
  ipcMain.handle("layout:set-template", (_event, { spreadId, templateId }) =>
    bridge.request("layout.set_template", {
      spread_id: Number(spreadId),
      template_id: String(templateId),
    }),
  );
  ipcMain.handle("layout:set-crop", (_event, { spreadId, cellIndex, crop }) =>
    bridge.request("layout.set_crop", {
      spread_id: Number(spreadId),
      cell_index: Number(cellIndex),
      crop,
    }),
  );
  ipcMain.handle("layout:recompose-spread", (_event, { spreadId }) =>
    bridge.request("layout.recompose_spread", { spread_id: Number(spreadId) }),
  );
  ipcMain.handle("database:job-status", () => jobState);
  ipcMain.handle("database:job-cancel", () => {
    if (activeJob) {
      activeJob.ailbumCancelled = true;
      activeJob.kill();
    }
    publishJob({ status: "cancelled", stage: "Операция отменена", current: null, total: null });
    return jobState;
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
