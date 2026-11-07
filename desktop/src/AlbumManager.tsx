import { useState } from "react";
import "./albums.css";

export type AlbumStatus = "draft" | "ordered" | "archived";
export type AlbumSummary = {
  id: number;
  title: string;
  status: AlbumStatus;
  photo_count: number;
  target_count: number;
  sources: string[];
  ordered_at: string | null;
  archived_at: string | null;
  updated_at: string;
};
export type UsageSummary = {
  database_bytes: number;
  proxies_bytes: number;
  feature_cache_bytes: number;
  images: { present: number; missing: number; archived: number };
};

type Maybe = void | Promise<void>;
type Props = {
  albums: AlbumSummary[];
  activeId: number | null;
  usage: UsageSummary | null;
  busy?: boolean;
  onOpen(id: number): Maybe;
  onStatus(id: number, status: AlbumStatus): Maybe;
  onRename(id: number, title: string): Maybe;
  onDelete(id: number, forgetDecisions: boolean): Maybe;
  onArchive(id: number): Maybe;
};

const GROUPS: { status: AlbumStatus; title: string }[] = [
  { status: "draft", title: "Черновики" },
  { status: "ordered", title: "Заказаны" },
  { status: "archived", title: "В архиве" },
];

const mb = (bytes: number) => `${(bytes / 1048576).toFixed(1)} МБ`;
const basename = (path: string) => path.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || path;
const day = (value: string | null) => (value ? value.slice(0, 10) : "");

function Card({ album, active, busy, ...p }: { album: AlbumSummary; active: boolean; busy: boolean } & Omit<Props, "albums" | "activeId" | "usage" | "busy">) {
  const [editing, setEditing] = useState(false);
  const [title, setTitle] = useState(album.title);
  const { id, status } = album;

  const commit = async () => {
    const next = title.trim();
    setEditing(false);
    if (next && next !== album.title) await p.onRename(id, next);
    else setTitle(album.title);
  };
  const release = () => {
    const text = `Освободить место для «${album.title}»? Экспорт будет проверен, построятся превью, оригиналы уйдут в Корзину (${album.photo_count} фото).`;
    if (window.confirm(text)) void p.onArchive(id);
  };
  const remove = () => {
    if (window.confirm(`Удалить черновик «${album.title}»?`)) void p.onDelete(id, false);
  };
  const forget = () => {
    if (window.confirm(`Удалить альбом «${album.title}»? Решения по фото (выбор и обучение) будут забыты.`)) void p.onDelete(id, true);
  };
  const dates = [
    `изменён ${day(album.updated_at)}`,
    album.ordered_at ? `заказан ${day(album.ordered_at)}` : "",
    album.archived_at ? `в архиве ${day(album.archived_at)}` : "",
  ].filter(Boolean).join(" · ");

  return (
    <li className={`album-card${active ? " active" : ""}`}>
      <div className="album-card-head">
        {editing ? (
          <input
            className="album-title-input"
            value={title}
            autoFocus
            aria-label="Название альбома"
            onChange={(e) => setTitle(e.target.value)}
            onBlur={() => void commit()}
            onKeyDown={(e) => {
              if (e.key === "Enter") void commit();
              if (e.key === "Escape") { setTitle(album.title); setEditing(false); }
            }}
          />
        ) : (
          <strong
            className="album-title"
            title={status === "draft" ? "Двойной щелчок - переименовать" : undefined}
            onDoubleClick={status === "draft" && !busy ? () => setEditing(true) : undefined}
          >
            {album.title}
          </strong>
        )}
        <span className="album-count">{album.photo_count} из {album.target_count}</span>
      </div>
      <div className="album-meta">{album.sources.map(basename).join(", ")}</div>
      <div className="album-meta">{dates}</div>
      {status === "archived" && <div className="album-note">Оригиналы в Корзине, превью сохранены</div>}
      <div className="album-actions">
        <button disabled={busy} onClick={() => void p.onOpen(id)}>Открыть</button>
        {status === "draft" && <button disabled={busy} onClick={() => void p.onStatus(id, "ordered")}>Отметить заказанным</button>}
        {status === "draft" && <button className="danger" disabled={busy} onClick={remove}>Удалить черновик</button>}
        {status === "ordered" && <button disabled={busy} onClick={() => void p.onStatus(id, "draft")}>Вернуть в работу</button>}
        {status === "ordered" && <button disabled={busy} onClick={release}>Освободить место</button>}
        {status === "archived" && <button className="danger" disabled={busy} onClick={forget}>Удалить</button>}
      </div>
    </li>
  );
}

export function AlbumManager({ albums, activeId, usage, busy = false, ...handlers }: Props) {
  return (
    <section className="album-manager">
      {GROUPS.map(({ status, title }) => {
        const items = albums.filter((a) => a.status === status);
        return (
          <div className="album-group" key={status}>
            <h3>{title} <span>{items.length}</span></h3>
            {items.length === 0 ? (
              <p className="album-empty">Пусто</p>
            ) : (
              <ul>
                {items.map((album) => (
                  <Card key={album.id} album={album} active={album.id === activeId} busy={busy} {...handlers} />
                ))}
              </ul>
            )}
          </div>
        );
      })}
      {usage && (
        <footer className="album-usage">
          <span>База: {mb(usage.database_bytes)}</span>
          <span>Превью: {mb(usage.proxies_bytes)}</span>
          <span>Кэш признаков: {mb(usage.feature_cache_bytes)}</span>
          <span>Фото: {usage.images.present} на месте, {usage.images.missing} без файла, {usage.images.archived} в архиве</span>
        </footer>
      )}
    </section>
  );
}
