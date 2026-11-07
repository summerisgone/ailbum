import {
  Check,
  ChevronLeft,
  ChevronRight,
  CircleUserRound,
  Database,
  FolderInput,
  EyeOff,
  FolderOpen,
  Heart,
  ImageIcon,
  Images,
  Layers3,
  LayoutGrid,
  LoaderCircle,
  Merge,
  Pencil,
  Plus,
  Search,
  Settings2,
  Smile,
  Sparkles,
  UsersRound,
  X,
} from "lucide-react";
import {
  memo,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type RefObject,
} from "react";
import type {
  Face,
  FaceCollection,
  DatabaseJob,
  DatabaseSummary,
  Library,
  PeopleLibrary,
  PersonSummary,
  Photo,
  Story,
} from "./types";
import { LayoutSection } from "./layout/LayoutSection";

const DAY_FORMAT = new Intl.DateTimeFormat("ru-RU", {
  day: "numeric",
  month: "long",
  year: "numeric",
});
const WEEKDAY_FORMAT = new Intl.DateTimeFormat("ru-RU", { weekday: "long" });
const TIME_FORMAT = new Intl.DateTimeFormat("ru-RU", {
  hour: "2-digit",
  minute: "2-digit",
});

type GridRow =
  | { kind: "header"; key: string; story: Story; count: number; selectedCount: number }
  | { kind: "photos"; key: string; items: PhotoGridItem[] };

type PhotoGridItem =
  | { kind: "photo"; key: string; photo: Photo; series?: ExpandedSeries }
  | {
      kind: "stack";
      key: string;
      seriesKey: string;
      photos: Photo[];
      representative: Photo;
    };

type ExpandedSeries = {
  key: string;
  size: number;
  isFirst: boolean;
};

type StoryJump = { storyId: number; token: number };

function dateOf(photo: Photo) {
  return (photo.taken_at || photo.modified_at || "Без даты").slice(0, 10);
}

function dateLabel(value: string) {
  if (value === "Без даты") return { date: value, weekday: "" };
  const date = new Date(`${value}T12:00:00`);
  return {
    date: DAY_FORMAT.format(date),
    weekday: WEEKDAY_FORMAT.format(date),
  };
}

function storyPeriodLabel(story: Story) {
  if (!story.started_at) return "Время неизвестно";
  const start = new Date(story.started_at);
  const end = new Date(story.ended_at || story.started_at);
  if (Number.isNaN(start.valueOf()) || Number.isNaN(end.valueOf())) return "Время неизвестно";
  if (dateOfValue(start) === dateOfValue(end)) {
    const times = start.valueOf() === end.valueOf()
      ? TIME_FORMAT.format(start)
      : `${TIME_FORMAT.format(start)}–${TIME_FORMAT.format(end)}`;
    return `${DAY_FORMAT.format(start)} · ${times}`;
  }
  return `${DAY_FORMAT.format(start)} — ${DAY_FORMAT.format(end)}`;
}

function dateOfValue(value: Date) {
  return `${value.getFullYear()}-${value.getMonth()}-${value.getDate()}`;
}

function scoreOf(photo: Photo) {
  return photo.quality == null ? null : Math.round(photo.quality * 100);
}

function isPortraitPhoto(photo: Photo) {
  if (photo.width == null || photo.height == null) return false;
  const swapsAxes = [5, 6, 7, 8].includes(photo.orientation ?? 1);
  const displayWidth = swapsAxes ? photo.height : photo.width;
  const displayHeight = swapsAxes ? photo.width : photo.height;
  return displayHeight > displayWidth;
}

function stackRepresentative(photos: Photo[]) {
  return [...photos].sort((left, right) => {
    if (left.favorite !== right.favorite) return left.favorite ? -1 : 1;
    if (left.auto_selected !== right.auto_selected) return left.auto_selected ? -1 : 1;
    return (right.quality ?? -1) - (left.quality ?? -1);
  })[0];
}

function App() {
  const [library, setLibrary] = useState<Library | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState<Set<number>>(() => new Set());
  const [query, setQuery] = useState("");
  const [targetDraft, setTargetDraft] = useState("24");
  const [section, setSection] = useState<"photos" | "people" | "layout">("photos");
  const [viewerPhotoId, setViewerPhotoId] = useState<number | null>(null);
  const [storyJump, setStoryJump] = useState<StoryJump | null>(null);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [databaseJob, setDatabaseJob] = useState<DatabaseJob>({ status: "idle" });

  const applyLibrary = useCallback((next: Library) => {
    setLibrary(next);
    setTargetDraft(String(next.target_count));
    setViewerPhotoId(null);
    setError(null);
  }, []);

  useEffect(() => {
    window.ailbum.bootstrap().then(applyLibrary).catch((reason) => setError(String(reason)));
  }, [applyLibrary]);

  useEffect(() => {
    window.ailbum.getDatabaseJob().then(setDatabaseJob).catch(() => undefined);
    return window.ailbum.onDatabaseJob(setDatabaseJob);
  }, []);

  useEffect(() => {
    if (databaseJob.status !== "complete") return;
    window.ailbum.bootstrap().then(applyLibrary).catch((reason) => setError(String(reason)));
  }, [applyLibrary, databaseJob.status]);

  const photos = useMemo(() => {
    if (!library) return [];
    const normalized = query.trim().toLocaleLowerCase("ru");
    if (!normalized) return library.photos;
    return library.photos.filter(
      (photo) =>
        photo.file_name.toLocaleLowerCase("ru").includes(normalized) ||
        photo.story_title?.toLocaleLowerCase("ru").includes(normalized) ||
        photo.people_names.some((name) => name.toLocaleLowerCase("ru").includes(normalized)) ||
        [...photo.scene_tags, ...photo.object_tags].some((tag) =>
          tag.label.toLocaleLowerCase("ru").includes(normalized),
        ),
    );
  }, [library, query]);

  const selected = useMemo(
    () =>
      (library?.photos ?? [])
        .filter((photo) => photo.favorite)
        .sort(
          (left, right) =>
            (left.selection_position ?? Number.MAX_SAFE_INTEGER) -
            (right.selection_position ?? Number.MAX_SAFE_INTEGER),
        ),
    [library],
  );

  const selectedCountByStory = useMemo(() => {
    const counts = new Map<number, number>();
    for (const photo of library?.photos ?? []) {
      if (!photo.favorite) continue;
      const storyId = photo.story_id ?? 0;
      counts.set(storyId, (counts.get(storyId) ?? 0) + 1);
    }
    return counts;
  }, [library?.photos]);

  const jumpToPhotoStory = useCallback((photo: Photo) => {
    if (photo.story_id == null) return;
    setQuery("");
    setStoryJump((current) => ({
      storyId: photo.story_id as number,
      token: (current?.token ?? 0) + 1,
    }));
  }, []);

  const toggleFavorite = useCallback(
    async (photo: Photo, favorite: boolean) => {
      if (!library?.run || pending.has(photo.id)) return;
      const previous = library;
      const maxPosition = Math.max(
        0,
        ...library.photos.map((item) => item.selection_position ?? 0),
      );
      setPending((current) => new Set(current).add(photo.id));
      setLibrary({
        ...library,
        selected_count: library.selected_count + (favorite ? 1 : -1),
        photos: library.photos.map((item) =>
          item.id === photo.id
            ? {
                ...item,
                favorite,
                selection_position: favorite ? maxPosition + 1 : null,
              }
            : item,
        ),
      });
      try {
        const result = await window.ailbum.setFavorite(library.run.id, photo.id, favorite);
        setLibrary((current) =>
          current ? { ...current, selected_count: result.selected_count } : current,
        );
      } catch (reason) {
        setLibrary(previous);
        setError(String(reason));
      } finally {
        setPending((current) => {
          const next = new Set(current);
          next.delete(photo.id);
          return next;
        });
      }
    },
    [library, pending],
  );

  const openPhotosAtStory = useCallback((storyId: number | null) => {
    setSection("photos");
    setQuery("");
    if (storyId == null) return;
    setStoryJump((current) => ({ storyId, token: (current?.token ?? 0) + 1 }));
  }, []);

  const setFavoriteById = useCallback(
    async (imageId: number, favorite: boolean) => {
      const photo = library?.photos.find((item) => item.id === imageId);
      if (!photo) throw new Error(`Фото ${imageId} не найдено в каталоге`);
      await toggleFavorite(photo, favorite);
    },
    [library, toggleFavorite],
  );

  const saveTarget = useCallback(async () => {
    if (!library?.run) return;
    const parsed = Math.min(999, Math.max(1, Number.parseInt(targetDraft, 10) || 1));
    setTargetDraft(String(parsed));
    setLibrary((current) => (current ? { ...current, target_count: parsed } : current));
    try {
      await window.ailbum.setTarget(library.run.id, parsed);
    } catch (reason) {
      setError(String(reason));
    }
  }, [library?.run, targetDraft]);

  const chooseDatabase = useCallback(async () => {
    try {
      const next = await window.ailbum.chooseDatabase();
      if (next) applyLibrary(next);
    } catch (reason) {
      setError(String(reason));
    }
  }, [applyLibrary]);

  if (!library && !error) {
    return (
      <div className="loading-screen">
        <LoaderCircle className="spin" size={24} />
        <span>Открываем каталог…</span>
      </div>
    );
  }

  return (
    <div className="app-shell" data-platform={window.ailbum.platform}>
      <aside className="sidebar">
        <div className="brand" aria-label="Ailbum">
          <span className="brand-mark"><ImageIcon size={21} strokeWidth={2.4} /></span>
          <span>A</span>
        </div>
        <nav className="primary-nav" aria-label="Разделы">
          <button
            className={`nav-button${section === "photos" ? " active" : ""}`}
            title="Отбор фотографий"
            onClick={() => setSection("photos")}
          >
            <Images size={22} />
          </button>
          <button
            className={`nav-button${section === "people" ? " active" : ""}`}
            title="Люди и лица"
            data-section="people"
            onClick={() => setSection("people")}
          >
            <UsersRound size={22} />
          </button>
          <button
            className={`nav-button${section === "layout" ? " active" : ""}`}
            title="Раскладка"
            data-section="layout"
            onClick={() => setSection("layout")}
          >
            <LayoutGrid size={22} />
          </button>
        </nav>
        <button
          className={`nav-button sidebar-bottom${settingsOpen ? " active" : ""}`}
          title="Базы данных и анализ"
          aria-label="Базы данных и анализ"
          onClick={() => setSettingsOpen(true)}
        >
          <Settings2 size={21} />
          {databaseJob.status === "running" && <span className="job-dot" />}
        </button>
      </aside>

      <main className="workspace">
        <header className="topbar">
          <div className="title-block">
            <h1>{section === "photos" ? "Отбор фотографий" : section === "people" ? "Люди и лица" : "Раскладка"}</h1>
            <button className="database-button" onClick={chooseDatabase} title={library?.database}>
              <Database size={13} />
              <span>{library?.database.split(/[\\/]/).at(-1) ?? "Каталог"}</span>
            </button>
          </div>
          {section === "photos" && <label className="search-box">
            <Search size={17} />
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Фото, человек или сюжет"
              aria-label="Поиск фотографий"
            />
            {query && (
              <button onClick={() => setQuery("")} aria-label="Очистить поиск"><X size={14} /></button>
            )}
          </label>}
          {section === "photos" && <div className="target-control">
            <span>Нужно выбрать</span>
            <input
              value={targetDraft}
              onChange={(event) => setTargetDraft(event.target.value.replace(/\D/g, ""))}
              onBlur={saveTarget}
              onKeyDown={(event) => event.key === "Enter" && event.currentTarget.blur()}
              inputMode="numeric"
              aria-label="Целевое количество фотографий"
              disabled={!library?.run}
            />
            <span>фото</span>
          </div>}
          {section === "photos" && <div className="selection-counter" data-complete={selected.length >= (library?.target_count ?? 1)}>
            <Check size={16} />
            <strong>{selected.length}</strong>
            <span>/ {library?.target_count ?? 0}</span>
          </div>}
          <button className="avatar" aria-label="Профиль"><CircleUserRound size={20} /></button>
        </header>

        {error && (
          <div className="error-banner">
            <span>{error}</span>
            <button onClick={() => setError(null)} aria-label="Закрыть"><X size={15} /></button>
          </div>
        )}

        {section === "people" ? (
          <PeopleEditor database={library?.database ?? ""} onError={setError} />
        ) : section === "layout" ? (
          library?.run ? (
            <LayoutSection
              key={library.run.id}
              runId={library.run.id}
              onError={setError}
              onOpenPhotos={openPhotosAtStory}
              onSetFavorite={setFavoriteById}
            />
          ) : (
            <EmptyState onChooseDatabase={chooseDatabase} hasPhotos={Boolean(library?.photos.length)} />
          )
        ) : !library?.run ? (
          <EmptyState onChooseDatabase={chooseDatabase} hasPhotos={Boolean(library?.photos.length)} />
        ) : (
          <>
            <div className="collection-bar">
              <div>
                <span className="eyebrow">Последний анализ</span>
                <strong>{photos.length} фото</strong>
                {query && <span className="muted">из {library.photos.length}</span>}
              </div>
              <div className="legend">
                <span><Sparkles size={13} /> рекомендация</span>
                <span><Layers3 size={13} /> похожие кадры</span>
                <span><UsersRound size={13} /> лица</span>
              </div>
            </div>
            <VirtualPhotoGrid
              key={library.run.id}
              photos={photos}
              stories={library.stories}
              selectedCountByStory={selectedCountByStory}
              pending={pending}
              storyJump={storyJump}
              onToggle={toggleFavorite}
              onOpen={(photo) => setViewerPhotoId(photo.id)}
            />
            <SelectionTray
              photos={selected}
              target={library.target_count}
              pending={pending}
              onRemove={(photo) => toggleFavorite(photo, false)}
              onJump={jumpToPhotoStory}
            />
          </>
        )}
      </main>
      {viewerPhotoId != null && (
        <PhotoViewer
          photos={photos}
          photoId={viewerPhotoId}
          pending={pending.has(viewerPhotoId)}
          onToggle={toggleFavorite}
          onChange={setViewerPhotoId}
          onClose={() => setViewerPhotoId(null)}
        />
      )}
      {settingsOpen && library && (
        <DatabaseManager
          library={library}
          job={databaseJob}
          onJob={setDatabaseJob}
          onLibrary={applyLibrary}
          onClose={() => setSettingsOpen(false)}
          onError={setError}
        />
      )}
    </div>
  );
}

function DatabaseManager({
  library,
  job,
  onJob,
  onLibrary,
  onClose,
  onError,
}: {
  library: Library;
  job: DatabaseJob;
  onJob(job: DatabaseJob): void;
  onLibrary(library: Library): void;
  onClose(): void;
  onError(message: string): void;
}) {
  const [summary, setSummary] = useState<DatabaseSummary | null>(null);
  const [folders, setFolders] = useState<string[]>([]);
  const [dragging, setDragging] = useState(false);
  const running = job.status === "running";
  const progress = job.current != null && job.total
    ? Math.min(100, Math.round((job.current / job.total) * 100))
    : null;

  const refreshSummary = useCallback(() => {
    window.ailbum.getDatabaseSummary().then(setSummary).catch((reason) => onError(String(reason)));
  }, [onError]);

  useEffect(refreshSummary, [library.database, refreshSummary]);
  useEffect(() => {
    if (job.status === "complete") refreshSummary();
  }, [job.status, refreshSummary]);
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => event.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const switchDatabase = async (create: boolean) => {
    try {
      const next = create
        ? await window.ailbum.createDatabase()
        : await window.ailbum.chooseDatabase();
      if (next) {
        onLibrary(next);
        setFolders([]);
        onJob({ status: "idle" });
      }
    } catch (reason) {
      onError(String(reason));
    }
  };

  const addFolders = (paths: string[]) => {
    setFolders((current) => [...new Set([...current, ...paths.filter(Boolean)])]);
  };

  const chooseFolders = async () => {
    try {
      addFolders(await window.ailbum.choosePhotoFolders());
    } catch (reason) {
      onError(String(reason));
    }
  };

  const startJob = async (kind: "index" | "analyze", sources: string[] = []) => {
    try {
      onJob(await window.ailbum.startDatabaseJob(kind, sources));
    } catch (reason) {
      onError(String(reason));
    }
  };

  const databaseName = library.database.split(/[\\/]/).at(-1);
  return (
    <div className="database-overlay" role="dialog" aria-modal="true" aria-label="Управление базами данных" onClick={onClose}>
      <section className="database-manager" onClick={(event) => event.stopPropagation()}>
        <header className="database-manager-header">
          <div>
            <span className="eyebrow">Настройки</span>
            <h2>База данных и анализ</h2>
          </div>
          <button onClick={onClose} aria-label="Закрыть"><X size={20} /></button>
        </header>

        <div className="database-manager-body">
          <section className="manager-section current-database">
            <div className="section-heading">
              <div className="manager-icon"><Database size={19} /></div>
              <div><strong>{databaseName}</strong><span title={library.database}>{library.database}</span></div>
            </div>
            <div className="database-stats">
              <div><strong>{summary?.available ?? library.photos.length}</strong><span>фото</span></div>
              <div><strong>{summary?.analysis_runs ?? (library.run ? 1 : 0)}</strong><span>анализов</span></div>
              <div><strong>{summary?.people ?? 0}</strong><span>людей</span></div>
              <div><strong>{summary?.stories ?? library.stories.length}</strong><span>сюжетов</span></div>
            </div>
            <div className="manager-actions">
              <button disabled={running} onClick={() => switchDatabase(false)}><FolderOpen size={15} />Открыть другую</button>
              <button disabled={running} onClick={() => switchDatabase(true)}><Plus size={15} />Создать новую</button>
            </div>
          </section>

          <section className="manager-section">
            <div className="section-copy">
              <strong>Добавить фотографии</strong>
              <span>Перетащите одну или несколько папок. В базу попадут фотографии из всех вложенных каталогов.</span>
            </div>
            <div
              className={`folder-drop${dragging ? " dragging" : ""}`}
              onDragEnter={(event) => { event.preventDefault(); setDragging(true); }}
              onDragOver={(event) => { event.preventDefault(); event.dataTransfer.dropEffect = "copy"; }}
              onDragLeave={(event) => {
                if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setDragging(false);
              }}
              onDrop={(event) => {
                event.preventDefault();
                setDragging(false);
                addFolders(Array.from(event.dataTransfer.files, (file) => window.ailbum.pathForFile(file)));
              }}
            >
              <FolderInput size={25} />
              <strong>{dragging ? "Отпустите папки здесь" : "Перетащите папки с фото"}</strong>
              <span>или</span>
              <button onClick={chooseFolders} disabled={running}>Выбрать папки</button>
            </div>
            {folders.length > 0 && (
              <div className="folder-queue">
                {folders.map((folder) => (
                  <div key={folder} title={folder}>
                    <FolderOpen size={14} /><span>{folder}</span>
                    <button disabled={running} onClick={() => setFolders((items) => items.filter((item) => item !== folder))} aria-label="Убрать папку"><X size={13} /></button>
                  </div>
                ))}
              </div>
            )}
            <button className="manager-primary" disabled={running || folders.length === 0} onClick={() => startJob("index", folders)}>
              {running && job.kind === "index" ? <LoaderCircle className="spin" size={16} /> : <Plus size={16} />}
              Добавить в базу
            </button>
          </section>

          <section className="manager-section analysis-section">
            <div className="section-copy">
              <strong>{folders.length === 1 ? "Анализ выбранной папки" : library.run ? "Повторный анализ" : "Анализ фотографий"}</strong>
              <span>{folders.length === 1 ? `Источник: ${folders[0]}` : library.run ? `Последний источник: ${library.run.source}` : "Выберите одну папку выше, чтобы запустить первый анализ."}</span>
            </div>
            <button
              className="manager-primary secondary"
              disabled={running || (!library.run && folders.length !== 1)}
              onClick={() => startJob("analyze", folders.length === 1 ? folders : [])}
            >
              {running && job.kind === "analyze" ? <LoaderCircle className="spin" size={16} /> : <Sparkles size={16} />}
              {folders.length === 1 || !library.run ? "Запустить анализ папки" : "Запустить анализ заново"}
            </button>
          </section>

          {job.status !== "idle" && (
            <section className={`job-panel ${job.status}`}>
              <div className="job-heading">
                <div>
                  {running ? <LoaderCircle className="spin" size={18} /> : job.status === "complete" ? <Check size={18} /> : <X size={18} />}
                  <span><strong>{job.stage || (job.status === "complete" ? "Готово" : "Операция остановлена")}</strong><small>{job.detail}</small></span>
                </div>
                {running && <button onClick={() => window.ailbum.cancelDatabaseJob().then(onJob)}>Отменить</button>}
              </div>
              {running && (
                <div className={`job-progress${progress == null ? " indeterminate" : ""}`}>
                  <span style={progress == null ? undefined : { width: `${progress}%` }} />
                </div>
              )}
              {running && job.current != null && job.total != null && <p>{job.current} из {job.total} фотографий</p>}
              {job.status === "error" && <p>{job.error}</p>}
              {job.status === "complete" && <p>Данные обновлены, каталог перезагружен.</p>}
            </section>
          )}
        </div>
      </section>
    </div>
  );
}

function PeopleEditor({ database, onError }: { database: string; onError(message: string): void }) {
  const [peopleLibrary, setPeopleLibrary] = useState<PeopleLibrary | null>(null);
  const [activePersonId, setActivePersonId] = useState<number | null | undefined>(undefined);
  const [collection, setCollection] = useState<FaceCollection | null>(null);
  const [nameDraft, setNameDraft] = useState("");
  const [loadingFaces, setLoadingFaces] = useState(false);
  const [pendingFaces, setPendingFaces] = useState<Set<number>>(() => new Set());
  const [savingName, setSavingName] = useState(false);
  const [mergeTarget, setMergeTarget] = useState<PersonSummary | null>(null);
  const [merging, setMerging] = useState(false);

  const refreshPeople = useCallback(async () => {
    const next = await window.ailbum.getPeople();
    setPeopleLibrary(next);
    return next;
  }, []);

  useEffect(() => {
    setPeopleLibrary(null);
    setCollection(null);
    setActivePersonId(undefined);
    window.ailbum
      .getPeople()
      .then((next) => {
        setPeopleLibrary(next);
        setActivePersonId(next.people[0]?.id ?? null);
      })
      .catch((reason) => onError(String(reason)));
  }, [database, onError]);

  const loadFaces = useCallback(async (personId: number | null) => {
    setLoadingFaces(true);
    try {
      const next = await window.ailbum.getFaces(personId);
      setCollection(next);
      setNameDraft(next.person?.name ?? "");
    } finally {
      setLoadingFaces(false);
    }
  }, []);

  useEffect(() => {
    setMergeTarget(null);
    if (activePersonId === undefined) return;
    setCollection(null);
    loadFaces(activePersonId).catch((reason) => onError(String(reason)));
  }, [activePersonId, loadFaces, onError]);

  const activePerson = collection?.person?.id === activePersonId ? collection?.person ?? null : null;
  const mergeCandidates = (peopleLibrary?.people ?? []).filter(
    (person) => activePerson && person.id !== activePerson.id && person.embedding_model === activePerson.embedding_model,
  );
  const normalizedDraft = nameDraft.trim().toLocaleLowerCase("ru");
  const draftMatchesTarget = mergeTarget?.name?.toLocaleLowerCase("ru") === normalizedDraft;

  const commitName = useCallback(async () => {
    if (!activePerson || savingName) return;
    const name = nameDraft.trim();
    const personId = activePerson.id;
    setSavingName(true);
    setMergeTarget(null);
    try {
      await window.ailbum.setPersonName(personId, name);
      await refreshPeople();
      setCollection((current) =>
        current?.person?.id === personId
          ? { ...current, person: { ...current.person, name: name || null } }
          : current,
      );
    } catch (reason) {
      onError(String(reason));
    } finally {
      setSavingName(false);
    }
  }, [activePerson, nameDraft, onError, refreshPeople, savingName]);

  const saveName = useCallback(async () => {
    if (!activePerson || nameDraft.trim() === (activePerson.name ?? "")) return;
    // The typed name already belongs to someone: this is most likely the same person.
    const sameName = normalizedDraft
      ? mergeCandidates.find((person) => person.name?.toLocaleLowerCase("ru") === normalizedDraft)
      : undefined;
    if (sameName) {
      setMergeTarget(sameName);
      return;
    }
    await commitName();
  }, [activePerson, commitName, mergeCandidates, nameDraft, normalizedDraft]);

  const dismissMerge = useCallback(() => {
    if (draftMatchesTarget) {
      void commitName();
      return;
    }
    setNameDraft(activePerson?.name ?? "");
    setMergeTarget(null);
  }, [activePerson, commitName, draftMatchesTarget]);

  const mergeActivePerson = useCallback(async () => {
    if (!activePerson || !mergeTarget || merging) return;
    setMerging(true);
    try {
      await window.ailbum.mergePerson(activePerson.id, mergeTarget.id);
      await refreshPeople();
      setActivePersonId(mergeTarget.id);
    } catch (reason) {
      onError(String(reason));
    } finally {
      setMerging(false);
    }
  }, [activePerson, mergeTarget, merging, onError, refreshPeople]);

  const assignFace = useCallback(
    async (face: Face, destination: string) => {
      if (pendingFaces.has(face.id)) return;
      setPendingFaces((current) => new Set(current).add(face.id));
      try {
        if (destination === "new") {
          const person = await window.ailbum.createPersonFromFace(face.id, "");
          await refreshPeople();
          setActivePersonId(person.id);
        } else {
          const personId = destination === "none" ? null : Number(destination);
          await window.ailbum.assignFace(face.id, personId);
          await refreshPeople();
          if (activePersonId !== undefined) await loadFaces(activePersonId);
        }
      } catch (reason) {
        onError(String(reason));
      } finally {
        setPendingFaces((current) => {
          const next = new Set(current);
          next.delete(face.id);
          return next;
        });
      }
    },
    [activePersonId, loadFaces, onError, pendingFaces, refreshPeople],
  );

  if (!peopleLibrary) {
    return <div className="loading-screen"><LoaderCircle className="spin" size={22} />Загружаем лица…</div>;
  }

  return (
    <div className="people-editor">
      <aside className="people-panel">
        <div className="people-panel-heading">
          <span>Люди</span>
          <strong>{peopleLibrary.people.length}</strong>
        </div>
        <div className="people-list">
          <button
            className={`person-row${activePersonId === null ? " active" : ""}`}
            onClick={() => setActivePersonId(null)}
          >
            <span className="person-avatar unassigned"><UsersRound size={18} /></span>
            <span><strong>Без человека</strong><small>Нужно разобрать</small></span>
            <b>{peopleLibrary.unassigned_count}</b>
          </button>
          {peopleLibrary.people.map((person) => (
            <button
              className={`person-row${activePersonId === person.id ? " active" : ""}`}
              onClick={() => setActivePersonId(person.id)}
              key={person.id}
            >
              <span className="person-avatar">{(person.name?.trim()[0] || "?").toLocaleUpperCase("ru")}</span>
              <span>
                <strong>{person.name || `Человек ${person.id}`}</strong>
                <small>{person.photo_count} фото</small>
              </span>
              <b>{person.face_count}</b>
            </button>
          ))}
        </div>
      </aside>

      <section className="faces-workspace">
        <header className="faces-header">
          <div>
            <span className="eyebrow">{activePersonId == null ? "Не назначены" : "Выбранный человек"}</span>
            {activePersonId == null ? (
              <h2>Лица без связи</h2>
            ) : (
              <form
                className="person-name-form"
                onSubmit={(event) => { event.preventDefault(); void saveName(); }}
              >
                <input
                  value={nameDraft}
                  onChange={(event) => {
                    setNameDraft(event.target.value);
                    setMergeTarget(null);
                  }}
                  onBlur={() => void saveName()}
                  placeholder={`Человек ${activePersonId}`}
                  title="Имя применяется ко всем фото этого человека"
                  aria-label="Имя человека"
                />
                {savingName ? <LoaderCircle className="spin" size={16} /> : <Pencil size={14} />}
              </form>
            )}
          </div>
          <div className="faces-header-actions">
            {mergeCandidates.length > 0 && (
              <label className="face-assignment person-merge">
                <Merge size={14} />
                <select
                  value=""
                  disabled={merging}
                  onChange={(event) =>
                    setMergeTarget(
                      mergeCandidates.find((person) => person.id === Number(event.target.value)) ?? null,
                    )
                  }
                  aria-label="Объединить с другим человеком"
                >
                  <option value="" disabled>Это тот же человек, что…</option>
                  {mergeCandidates.map((person) => (
                    <option value={person.id} key={person.id}>
                      {person.name || `Человек ${person.id}`} · {person.photo_count} фото
                    </option>
                  ))}
                </select>
              </label>
            )}
            <div className="face-summary">
              <strong>{collection?.faces.length ?? 0}</strong>
              <span>наблюдений лица</span>
              {collection?.person && <small>{collection.person.embedding_model}</small>}
            </div>
          </div>
        </header>

        {activePerson && mergeTarget && (
          <div className="merge-confirm" role="alertdialog" aria-label="Объединение людей">
            <p>
              <strong>{activePerson.name || `Человек ${activePerson.id}`}</strong>
              {" и "}
              <strong>{mergeTarget.name || `Человек ${mergeTarget.id}`}</strong>
              {" - один человек? "}
              Все лица перейдут к одной записи для всех фото. Отменить объединение можно только вручную.
            </p>
            <button className="merge-confirm-primary" disabled={merging} onClick={() => void mergeActivePerson()}>
              {merging ? <LoaderCircle className="spin" size={13} /> : <Merge size={13} />}
              Объединить
            </button>
            <button disabled={merging || savingName} onClick={dismissMerge}>
              {draftMatchesTarget ? "Это другой человек" : "Отмена"}
            </button>
          </div>
        )}

        {loadingFaces || !collection ? (
          <div className="loading-screen"><LoaderCircle className="spin" size={22} />Загружаем лица…</div>
        ) : collection.faces.length === 0 ? (
          <div className="faces-empty">
            <span><UsersRound size={25} /></span>
            <h3>{activePersonId == null ? "Все лица распределены" : "У человека пока нет лиц"}</h3>
            <p>Назначение можно изменить в меню на карточке любого лица.</p>
          </div>
        ) : (
          <div className="faces-scroller">
            <div className="faces-grid">
              {collection.faces.map((face) => (
                <FaceCard
                  face={face}
                  people={peopleLibrary.people}
                  pending={pendingFaces.has(face.id)}
                  onAssign={assignFace}
                  key={face.id}
                />
              ))}
            </div>
          </div>
        )}
      </section>
    </div>
  );
}

const FaceCard = memo(function FaceCard({
  face,
  people,
  pending,
  onAssign,
}: {
  face: Face;
  people: PersonSummary[];
  pending: boolean;
  onAssign(face: Face, destination: string): void;
}) {
  const date = face.taken_at ? new Date(face.taken_at) : null;
  const currentValue = face.person_id == null ? "none" : String(face.person_id);
  return (
    <article className="face-card">
      <div className="face-crop">
        <img src={window.ailbum.faceUrl(face.id)} alt="" loading="lazy" decoding="async" />
        {pending && <span className="face-pending"><LoaderCircle className="spin" size={19} /></span>}
        <span className="face-confidence">{Math.round(face.confidence * 100)}%</span>
      </div>
      <div className="face-meta">
        <strong title={face.file_name}>{face.file_name}</strong>
        <span>{date && !Number.isNaN(date.valueOf()) ? DAY_FORMAT.format(date) : "Дата неизвестна"}</span>
      </div>
      <label className="face-assignment">
        <UsersRound size={14} />
        <select
          value={currentValue}
          disabled={pending}
          onChange={(event) => onAssign(face, event.target.value)}
          aria-label={`Назначение лица из ${face.file_name}`}
        >
          <option value="none">Без человека</option>
          <option value="new">＋ Новый человек</option>
          {people
            .filter((person) => person.embedding_model === face.embedding_model)
            .map((person) => (
              <option value={person.id} key={person.id}>
                {person.name || `Человек ${person.id}`} · {person.face_count}
              </option>
            ))}
        </select>
      </label>
    </article>
  );
});

function EmptyState({ onChooseDatabase, hasPhotos }: { onChooseDatabase(): void; hasPhotos: boolean }) {
  return (
    <section className="empty-state">
      <span className="empty-icon"><FolderOpen size={28} /></span>
      <h2>{hasPhotos ? "Сначала запустите анализ" : "В каталоге пока нет фотографий"}</h2>
      <p>
        {hasPhotos
          ? "Фотографии проиндексированы, но для скоринга и отбора нужен завершённый запуск CLI."
          : "Выберите SQLite-каталог Ailbum или проиндексируйте папку через CLI."}
      </p>
      <button className="primary-button" onClick={onChooseDatabase}>Выбрать базу</button>
    </section>
  );
}

function useElementSize<T extends HTMLElement>(ref: RefObject<T | null>) {
  const [size, setSize] = useState({ width: 0, height: 0 });
  useEffect(() => {
    const element = ref.current;
    if (!element) return;
    const update = () => setSize({ width: element.clientWidth, height: element.clientHeight });
    update();
    const observer = new ResizeObserver(update);
    observer.observe(element);
    return () => observer.disconnect();
  }, [ref]);
  return size;
}

function columnCount(width: number) {
  if (width >= 1540) return 6;
  if (width >= 1260) return 5;
  if (width >= 980) return 4;
  if (width >= 720) return 3;
  return 2;
}

function VirtualPhotoGrid({
  photos,
  stories,
  selectedCountByStory,
  pending,
  storyJump,
  onToggle,
  onOpen,
}: {
  photos: Photo[];
  stories: Story[];
  selectedCountByStory: Map<number, number>;
  pending: Set<number>;
  storyJump: StoryJump | null;
  onToggle(photo: Photo, favorite: boolean): void;
  onOpen(photo: Photo): void;
}) {
  const scrollerRef = useRef<HTMLDivElement>(null);
  const { width, height } = useElementSize(scrollerRef);
  const [scrollTop, setScrollTop] = useState(0);
  const [highlightedStory, setHighlightedStory] = useState<number | null>(null);
  const [expandedSeries, setExpandedSeries] = useState<Set<string>>(() => new Set());
  const columns = columnCount(width);
  const cardWidth = Math.max(150, (width - 48 - (columns - 1) * 12) / columns);
  const photoRowHeight = Math.round(cardWidth * 0.68 + 46);

  const rows = useMemo(() => {
    const storyById = new Map(stories.map((story) => [story.id, story]));
    const groups = new Map<number, Photo[]>();
    for (const photo of photos) {
      const storyId = photo.story_id ?? 0;
      const group = groups.get(storyId);
      if (group) group.push(photo);
      else groups.set(storyId, [photo]);
    }
    const result: GridRow[] = [];
    for (const [storyId, items] of groups) {
      const story = storyById.get(storyId) ?? {
        id: storyId,
        title: items[0]?.story_title || "Без сюжета",
        started_at: items[0]?.taken_at || items[0]?.modified_at || null,
        ended_at: items.at(-1)?.taken_at || items.at(-1)?.modified_at || null,
        representative_image_id: items[0]?.id ?? null,
        photo_count: items.length,
        naming_model: null,
      };
      result.push({
        kind: "header",
        key: `header-${storyId}`,
        story,
        count: story.photo_count,
        selectedCount: selectedCountByStory.get(storyId) ?? 0,
      });

      const series = new Map<number, Photo[]>();
      for (const photo of items) {
        if (photo.similar_cluster == null) continue;
        const members = series.get(photo.similar_cluster);
        if (members) members.push(photo);
        else series.set(photo.similar_cluster, [photo]);
      }

      const gridItems: PhotoGridItem[] = [];
      const emittedSeries = new Set<number>();
      for (const photo of items) {
        const cluster = photo.similar_cluster;
        const members = cluster == null ? undefined : series.get(cluster);
        if (cluster == null || !members || members.length < 2) {
          gridItems.push({ kind: "photo", key: `photo-${photo.id}`, photo });
          continue;
        }
        if (emittedSeries.has(cluster)) continue;
        emittedSeries.add(cluster);
        const seriesKey = `${storyId}:${cluster}`;
        if (expandedSeries.has(seriesKey)) {
          members.forEach((member, memberIndex) => {
            gridItems.push({
              kind: "photo",
              key: `photo-${member.id}`,
              photo: member,
              series: {
                key: seriesKey,
                size: members.length,
                isFirst: memberIndex === 0,
              },
            });
          });
        } else {
          gridItems.push({
            kind: "stack",
            key: `stack-${seriesKey}`,
            seriesKey,
            photos: members,
            representative: stackRepresentative(members),
          });
        }
      }

      for (let index = 0; index < gridItems.length; index += columns) {
        result.push({
          kind: "photos",
          key: `${storyId}-${index}`,
          items: gridItems.slice(index, index + columns),
        });
      }
    }
    return result;
  }, [photos, stories, selectedCountByStory, columns, expandedSeries]);

  const layout = useMemo(() => {
    const offsets: number[] = [];
    const heights: number[] = [];
    let total = 0;
    for (const row of rows) {
      offsets.push(total);
      const rowHeight = row.kind === "header" ? 62 : photoRowHeight;
      heights.push(rowHeight);
      total += rowHeight;
    }
    return { offsets, heights, total };
  }, [rows, photoRowHeight]);

  useEffect(() => {
    if (!storyJump || !scrollerRef.current) return;
    const rowIndex = rows.findIndex(
      (row) => row.kind === "header" && row.story.id === storyJump.storyId,
    );
    if (rowIndex < 0) return;
    scrollerRef.current.scrollTo({ top: layout.offsets[rowIndex], behavior: "smooth" });
    setHighlightedStory(storyJump.storyId);
    const timeout = window.setTimeout(() => setHighlightedStory(null), 1400);
    return () => window.clearTimeout(timeout);
  }, [storyJump, layout.offsets, rows]);

  useEffect(() => {
    const element = scrollerRef.current;
    if (!element) return;
    let frame = 0;
    const handleScroll = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => setScrollTop(element.scrollTop));
    };
    element.addEventListener("scroll", handleScroll, { passive: true });
    return () => {
      cancelAnimationFrame(frame);
      element.removeEventListener("scroll", handleScroll);
    };
  }, []);

  const visibleRows = useMemo(() => {
    const minimum = Math.max(0, scrollTop - 500);
    const maximum = scrollTop + height + 500;
    let low = 0;
    let high = layout.offsets.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (layout.offsets[middle] + layout.heights[middle] < minimum) low = middle + 1;
      else high = middle;
    }
    const result: Array<{ row: GridRow; index: number }> = [];
    for (let index = low; index < rows.length && layout.offsets[index] < maximum; index += 1) {
      result.push({ row: rows[index], index });
    }
    return result;
  }, [height, layout, rows, scrollTop]);

  if (!photos.length) {
    return <div className="no-results"><Search size={22} /><span>Ничего не найдено</span></div>;
  }

  return (
    <div className="photo-scroller" ref={scrollerRef}>
      <div className="virtual-canvas" style={{ height: layout.total }}>
        {visibleRows.map(({ row, index }) => {
          const style = {
            height: layout.heights[index],
            transform: `translateY(${layout.offsets[index]}px)`,
          } satisfies CSSProperties;
          if (row.kind === "header") {
            return (
              <div
                className={`story-header virtual-row${highlightedStory === row.story.id ? " highlighted" : ""}`}
                style={style}
                key={row.key}
              >
                <div className="story-heading">
                  <strong>{row.story.title}</strong>
                  <span>{storyPeriodLabel(row.story)}</span>
                </div>
                <div
                  className="story-counts"
                  data-has-selection={row.selectedCount > 0}
                  aria-label={`Выбрано ${row.selectedCount} из ${row.count} фотографий в событии`}
                >
                  <span>Выбрано <strong>{row.selectedCount}</strong></span>
                  <span>{row.count} фото</span>
                </div>
              </div>
            );
          }
          return (
            <div
              className="photo-row virtual-row"
              style={{ ...style, gridTemplateColumns: `repeat(${columns}, minmax(0, 1fr))` }}
              key={row.key}
            >
              {row.items.map((item) => item.kind === "stack" ? (
                <PhotoCard
                  photo={item.representative}
                  pending={pending.has(item.representative.id)}
                  onToggle={onToggle}
                  onOpen={() => setExpandedSeries((current) => {
                    const next = new Set(current);
                    next.add(item.seriesKey);
                    return next;
                  })}
                  stackSize={item.photos.length}
                  key={item.key}
                />
              ) : (
                <PhotoCard
                  photo={item.photo}
                  pending={pending.has(item.photo.id)}
                  onToggle={onToggle}
                  onOpen={onOpen}
                  expandedSeries={item.series}
                  onCollapseSeries={item.series?.isFirst ? () => {
                    setExpandedSeries((current) => {
                      const next = new Set(current);
                      next.delete(item.series!.key);
                      return next;
                    });
                  } : undefined}
                  key={item.key}
                />
              ))}
            </div>
          );
        })}
      </div>
    </div>
  );
}

const PhotoCard = memo(function PhotoCard({
  photo,
  pending,
  onToggle,
  onOpen,
  stackSize,
  expandedSeries,
  onCollapseSeries,
}: {
  photo: Photo;
  pending: boolean;
  onToggle(photo: Photo, favorite: boolean): void;
  onOpen(photo: Photo): void;
  stackSize?: number;
  expandedSeries?: ExpandedSeries;
  onCollapseSeries?(): void;
}) {
  const score = scoreOf(photo);
  const aesthetic =
    photo.aesthetic_score == null ? null : Math.round(photo.aesthetic_score * 100);
  const takenAt = photo.taken_at ? new Date(photo.taken_at) : null;
  return (
    <article
      className={`photo-card${photo.favorite ? " selected" : ""}${stackSize ? " stacked" : ""}${expandedSeries ? " series-expanded" : ""}`}
      onClick={() => onOpen(photo)}
      onKeyDown={(event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          onOpen(photo);
        }
      }}
      role="button"
      tabIndex={0}
      aria-label={stackSize ? `Раскрыть серию из ${stackSize} фотографий` : `Открыть ${photo.file_name}`}
    >
      <div className={`photo-frame${isPortraitPhoto(photo) ? " portrait" : ""}`}>
        <img src={window.ailbum.mediaUrl(photo.id)} alt={photo.file_name} loading="lazy" decoding="async" />
        {stackSize && (
          <span className="series-count" title={`Серия из ${stackSize} похожих фотографий`}>
            <Layers3 size={14} />{stackSize}
          </span>
        )}
        {onCollapseSeries && (
          <button
            className="series-collapse"
            onClick={(event) => {
              event.stopPropagation();
              onCollapseSeries();
            }}
            aria-label={`Свернуть серию из ${expandedSeries?.size ?? 0} фотографий`}
            title="Свернуть серию"
          >
            <Layers3 size={13} /> Свернуть
          </button>
        )}
        <div className="photo-topline">
          <span
            className={`score score-${score == null ? "none" : score >= 75 ? "high" : score >= 55 ? "mid" : "low"}`}
            title={`Техническое качество${score == null ? " не оценено" : `: ${score}`}`}
          >
            {score == null ? "—" : score}
          </span>
          <button
            className="favorite-button"
            onClick={(event) => {
              event.stopPropagation();
              onToggle(photo, !photo.favorite);
            }}
            disabled={pending}
            aria-label={photo.favorite ? "Убрать из выбранного" : "Добавить в выбранное"}
            title={photo.favorite ? "Убрать из выбранного" : "Добавить в выбранное"}
          >
            {pending ? <LoaderCircle className="spin" size={17} /> : photo.favorite ? <Check size={17} /> : <Plus size={17} />}
          </button>
        </div>
        <div className="photo-flags">
          {photo.auto_selected && <span title="Рекомендовано анализатором"><Sparkles size={13} /></span>}
          {photo.similar_cluster != null && <span title={`Группа похожих №${photo.similar_cluster}`}><Layers3 size={13} /></span>}
          {photo.face_count > 0 && <span title={`${photo.face_count} лиц`}><UsersRound size={13} />{photo.face_count}</span>}
          {photo.smiling_faces_count > 0 && <span title="Есть улыбки"><Smile size={13} /></span>}
          {photo.closed_eyes_count > 0 && <span className="warning" title="Обнаружены закрытые глаза"><EyeOff size={13} /></span>}
          {aesthetic != null && <span title={`CLIP-оценка эстетики: ${aesthetic}`}><Sparkles size={13} />{aesthetic}</span>}
          {photo.scene_tags[0] && (
            <span title={`Сюжет: ${photo.scene_tags.map((tag) => tag.label).join(", ")}`}>
              {photo.scene_tags[0].label}
            </span>
          )}
        </div>
      </div>
      <div className="photo-meta">
        <strong title={photo.file_name}>{stackSize ? `Серия · ${photo.file_name}` : photo.file_name}</strong>
        <span>{takenAt && !Number.isNaN(takenAt.valueOf()) ? TIME_FORMAT.format(takenAt) : "Время неизвестно"}</span>
      </div>
    </article>
  );
});

function PhotoViewer({
  photos,
  photoId,
  pending,
  onToggle,
  onChange,
  onClose,
}: {
  photos: Photo[];
  photoId: number;
  pending: boolean;
  onToggle(photo: Photo, favorite: boolean): void;
  onChange(photoId: number): void;
  onClose(): void;
}) {
  const [loaded, setLoaded] = useState(false);
  const index = photos.findIndex((photo) => photo.id === photoId);
  const photo = photos[index];
  const previous = index > 0 ? photos[index - 1] : null;
  const next = index >= 0 && index < photos.length - 1 ? photos[index + 1] : null;

  useEffect(() => setLoaded(false), [photoId]);
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
      else if (event.key === "ArrowLeft" && previous) onChange(previous.id);
      else if (event.key === "ArrowRight" && next) onChange(next.id);
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [next, onChange, onClose, previous]);

  useEffect(() => {
    if (!photo) onClose();
  }, [onClose, photo]);

  if (!photo) return null;
  const label = dateLabel(dateOf(photo));
  const score = scoreOf(photo);
  return (
    <div className="photo-viewer" role="dialog" aria-modal="true" aria-label={photo.file_name} onClick={onClose}>
      <header className="viewer-header" onClick={(event) => event.stopPropagation()}>
        <div>
          <strong className="viewer-file-name" title="Имя файла можно выделить и скопировать">
            {photo.file_name}
          </strong>
          <span>
            {photo.story_title && `${photo.story_title} · `}
            {label.date}{label.weekday ? ` · ${label.weekday}` : ""}
          </span>
        </div>
        <div className="viewer-position">
          <button
            className={`viewer-select${photo.favorite ? " selected" : ""}`}
            onClick={() => onToggle(photo, !photo.favorite)}
            disabled={pending}
            aria-pressed={photo.favorite}
            title={photo.favorite ? "Убрать из выбранного" : "Добавить в выбранное"}
          >
            {pending ? <LoaderCircle className="spin" size={14} /> : photo.favorite ? <Check size={14} /> : <Plus size={14} />}
            {photo.favorite ? "Выбрано" : "Выбрать"}
          </button>
          {score != null && <span>Качество <b>{score}</b></span>}
          <span>{index + 1} / {photos.length}</span>
        </div>
        <button onClick={onClose} title="Закрыть (Esc)" aria-label="Закрыть просмотр">
          <X size={21} />
        </button>
      </header>
      <div className="viewer-stage">
        {!loaded && <LoaderCircle className="viewer-loader spin" size={27} />}
        <img
          src={window.ailbum.originalUrl(photo.id)}
          alt={photo.file_name}
          onLoad={() => setLoaded(true)}
          onClick={(event) => event.stopPropagation()}
        />
        <button
          className="viewer-arrow previous"
          onClick={(event) => { event.stopPropagation(); if (previous) onChange(previous.id); }}
          disabled={!previous}
          title="Предыдущее фото (←)"
          aria-label="Предыдущее фото"
        >
          <ChevronLeft size={28} />
        </button>
        <button
          className="viewer-arrow next"
          onClick={(event) => { event.stopPropagation(); if (next) onChange(next.id); }}
          disabled={!next}
          title="Следующее фото (→)"
          aria-label="Следующее фото"
        >
          <ChevronRight size={28} />
        </button>
      </div>
    </div>
  );
}

function SelectionTray({
  photos,
  target,
  pending,
  onRemove,
  onJump,
}: {
  photos: Photo[];
  target: number;
  pending: Set<number>;
  onRemove(photo: Photo): void;
  onJump(photo: Photo): void;
}) {
  const progress = Math.min(100, Math.round((photos.length / target) * 100));
  const stripRef = useRef<HTMLDivElement>(null);
  return (
    <section className="selection-tray">
      <div className="tray-heading">
        <div>
          <Heart size={16} fill="currentColor" />
          <strong>Выбрано</strong>
          <span>{photos.length} из {target}</span>
        </div>
        <div className="progress-track" aria-label={`Выбрано ${progress}%`}>
          <span style={{ width: `${progress}%` }} />
        </div>
      </div>
      <div
        className="selection-strip"
        ref={stripRef}
        onWheel={(event) => {
          if (Math.abs(event.deltaY) > Math.abs(event.deltaX) && stripRef.current) {
            stripRef.current.scrollLeft += event.deltaY;
          }
        }}
      >
        {!photos.length && (
          <div className="tray-empty"><Plus size={18} /><span>Добавляйте лучшие кадры кнопкой на фотографии</span></div>
        )}
        {photos.map((photo, index) => (
          <div className="selected-thumb" key={photo.id}>
            <button
              className={`thumb-jump${isPortraitPhoto(photo) ? " portrait" : ""}`}
              onClick={() => onJump(photo)}
              title={`Перейти к сюжету: ${photo.story_title || "Без названия"}`}
              aria-label={`Перейти к ${photo.file_name} в сетке`}
            >
              <img src={window.ailbum.mediaUrl(photo.id)} alt="" loading="lazy" decoding="async" />
              <span className="thumb-index">{index + 1}</span>
            </button>
            <button
              className="thumb-remove"
              onClick={() => onRemove(photo)}
              disabled={pending.has(photo.id)}
              title="Убрать из выбранного"
              aria-label={`Убрать ${photo.file_name}`}
            >
              {pending.has(photo.id) ? <LoaderCircle className="spin" size={12} /> : <X size={12} />}
            </button>
          </div>
        ))}
      </div>
    </section>
  );
}

export default App;
