import {
  Check,
  CircleUserRound,
  Database,
  EyeOff,
  FolderOpen,
  Heart,
  ImageIcon,
  Images,
  Layers3,
  LoaderCircle,
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
import type { Library, Photo } from "./types";

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
  | { kind: "header"; key: string; date: string; count: number }
  | { kind: "photos"; key: string; photos: Photo[] };

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

function scoreOf(photo: Photo) {
  return photo.quality == null ? null : Math.round(photo.quality * 100);
}

function App() {
  const [library, setLibrary] = useState<Library | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState<Set<number>>(() => new Set());
  const [query, setQuery] = useState("");
  const [targetDraft, setTargetDraft] = useState("24");

  const applyLibrary = useCallback((next: Library) => {
    setLibrary(next);
    setTargetDraft(String(next.target_count));
    setError(null);
  }, []);

  useEffect(() => {
    window.ailbum.bootstrap().then(applyLibrary).catch((reason) => setError(String(reason)));
  }, [applyLibrary]);

  const photos = useMemo(() => {
    if (!library) return [];
    const normalized = query.trim().toLocaleLowerCase("ru");
    if (!normalized) return library.photos;
    return library.photos.filter(
      (photo) =>
        photo.file_name.toLocaleLowerCase("ru").includes(normalized) ||
        photo.people_names.some((name) => name.toLocaleLowerCase("ru").includes(normalized)),
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
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand" aria-label="Ailbum">
          <span className="brand-mark"><ImageIcon size={21} strokeWidth={2.4} /></span>
          <span>A</span>
        </div>
        <nav className="primary-nav" aria-label="Разделы">
          <button className="nav-button active" title="Отбор фотографий">
            <Images size={22} />
          </button>
          <button className="nav-button" title="Люди — следующий этап" disabled>
            <UsersRound size={22} />
            <span className="soon-dot" />
          </button>
        </nav>
        <button className="nav-button sidebar-bottom" title="Настройки">
          <Settings2 size={21} />
        </button>
      </aside>

      <main className="workspace">
        <header className="topbar">
          <div className="title-block">
            <h1>Отбор фотографий</h1>
            <button className="database-button" onClick={chooseDatabase} title={library?.database}>
              <Database size={13} />
              <span>{library?.database.split(/[\\/]/).at(-1) ?? "Каталог"}</span>
            </button>
          </div>
          <label className="search-box">
            <Search size={17} />
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Фото или человек"
              aria-label="Поиск фотографий"
            />
            {query && (
              <button onClick={() => setQuery("")} aria-label="Очистить поиск"><X size={14} /></button>
            )}
          </label>
          <div className="target-control">
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
          </div>
          <div className="selection-counter" data-complete={selected.length >= (library?.target_count ?? 1)}>
            <Check size={16} />
            <strong>{selected.length}</strong>
            <span>/ {library?.target_count ?? 0}</span>
          </div>
          <button className="avatar" aria-label="Профиль"><CircleUserRound size={20} /></button>
        </header>

        {error && (
          <div className="error-banner">
            <span>{error}</span>
            <button onClick={() => setError(null)} aria-label="Закрыть"><X size={15} /></button>
          </div>
        )}

        {!library?.run ? (
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
            <VirtualPhotoGrid photos={photos} pending={pending} onToggle={toggleFavorite} />
            <SelectionTray
              photos={selected}
              target={library.target_count}
              pending={pending}
              onRemove={(photo) => toggleFavorite(photo, false)}
            />
          </>
        )}
      </main>
    </div>
  );
}

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
  pending,
  onToggle,
}: {
  photos: Photo[];
  pending: Set<number>;
  onToggle(photo: Photo, favorite: boolean): void;
}) {
  const scrollerRef = useRef<HTMLDivElement>(null);
  const { width, height } = useElementSize(scrollerRef);
  const [scrollTop, setScrollTop] = useState(0);
  const columns = columnCount(width);
  const cardWidth = Math.max(150, (width - 48 - (columns - 1) * 12) / columns);
  const photoRowHeight = Math.round(cardWidth * 0.68 + 46);

  const rows = useMemo(() => {
    const groups = new Map<string, Photo[]>();
    for (const photo of photos) {
      const day = dateOf(photo);
      const group = groups.get(day);
      if (group) group.push(photo);
      else groups.set(day, [photo]);
    }
    const result: GridRow[] = [];
    for (const [date, items] of groups) {
      result.push({ kind: "header", key: `header-${date}`, date, count: items.length });
      for (let index = 0; index < items.length; index += columns) {
        result.push({
          kind: "photos",
          key: `${date}-${index}`,
          photos: items.slice(index, index + columns),
        });
      }
    }
    return result;
  }, [photos, columns]);

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
            const label = dateLabel(row.date);
            return (
              <div className="day-header virtual-row" style={style} key={row.key}>
                <div><strong>{label.date}</strong><span>{label.weekday}</span></div>
                <span>{row.count} фото</span>
              </div>
            );
          }
          return (
            <div
              className="photo-row virtual-row"
              style={{ ...style, gridTemplateColumns: `repeat(${columns}, minmax(0, 1fr))` }}
              key={row.key}
            >
              {row.photos.map((photo) => (
                <PhotoCard
                  photo={photo}
                  pending={pending.has(photo.id)}
                  onToggle={onToggle}
                  key={photo.id}
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
}: {
  photo: Photo;
  pending: boolean;
  onToggle(photo: Photo, favorite: boolean): void;
}) {
  const score = scoreOf(photo);
  const takenAt = photo.taken_at ? new Date(photo.taken_at) : null;
  return (
    <article className={`photo-card${photo.favorite ? " selected" : ""}`}>
      <div className="photo-frame">
        <img src={window.ailbum.mediaUrl(photo.id)} alt={photo.file_name} loading="lazy" decoding="async" />
        <div className="photo-topline">
          <span className={`score score-${score == null ? "none" : score >= 75 ? "high" : score >= 55 ? "mid" : "low"}`}>
            {score == null ? "—" : score}
          </span>
          <button
            className="favorite-button"
            onClick={() => onToggle(photo, !photo.favorite)}
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
        </div>
      </div>
      <div className="photo-meta">
        <strong title={photo.file_name}>{photo.file_name}</strong>
        <span>{takenAt && !Number.isNaN(takenAt.valueOf()) ? TIME_FORMAT.format(takenAt) : "Время неизвестно"}</span>
      </div>
    </article>
  );
});

function SelectionTray({
  photos,
  target,
  pending,
  onRemove,
}: {
  photos: Photo[];
  target: number;
  pending: Set<number>;
  onRemove(photo: Photo): void;
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
            <img src={window.ailbum.mediaUrl(photo.id)} alt="" loading="lazy" decoding="async" />
            <span className="thumb-index">{index + 1}</span>
            <button
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
