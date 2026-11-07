import { Check, ChevronLeft, ChevronRight, LoaderCircle, Plus, X } from "lucide-react";
import { useEffect, useState } from "react";
import type { LayoutAlternative } from "../types";
import { WARNING_LABELS } from "./SpreadView";

type Props = {
  title: string;
  items: LayoutAlternative[];
  startId: number;
  currentId: number | null;
  spreadId: number;
  busy: boolean;
  onReplace(imageId: number): void;
  onToggleSelection(imageId: number, selected: boolean): void;
  onClose(): void;
};

export function placedLabel(item: LayoutAlternative, spreadId: number, currentId: number | null) {
  if (item.image_id === currentId) return "В этой ячейке";
  if (!item.placed) return null;
  return item.placed.spread_id === spreadId ? "На этом развороте" : `На развороте ${item.placed.position}`;
}

export function LayoutViewer({
  title,
  items,
  startId,
  currentId,
  spreadId,
  busy,
  onReplace,
  onToggleSelection,
  onClose,
}: Props) {
  const [imageId, setImageId] = useState(startId);
  const [loaded, setLoaded] = useState(false);
  const index = Math.max(0, items.findIndex((item) => item.image_id === imageId));
  const item = items[index];
  const previous = index > 0 ? items[index - 1] : null;
  const next = index < items.length - 1 ? items[index + 1] : null;
  const canReplace = item != null && item.image_id !== currentId && !busy;

  useEffect(() => setLoaded(false), [imageId]);
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
      else if (event.key === "ArrowLeft" && previous) setImageId(previous.image_id);
      else if (event.key === "ArrowRight" && next) setImageId(next.image_id);
      else if (event.key === "Enter" && canReplace) onReplace(item.image_id);
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [canReplace, item, next, onClose, onReplace, previous]);

  if (!item) return null;
  const placed = placedLabel(item, spreadId, currentId);
  return (
    <div className="photo-viewer layout-viewer" role="dialog" aria-modal="true" aria-label={title} onClick={onClose}>
      <header className="viewer-header" onClick={(event) => event.stopPropagation()}>
        <div>
          <strong>{title}</strong>
          <span>
            Совпадение с ячейкой {Math.round(item.fit * 100)}%
            {placed && ` · ${placed}`}
            {item.warnings.length > 0 && ` · ${item.warnings.map((w) => WARNING_LABELS[w] ?? w).join(", ")}`}
          </span>
        </div>
        <div className="viewer-position">
          <button
            className={`viewer-select${item.in_selection ? " selected" : ""}`}
            disabled={busy}
            onClick={() => onToggleSelection(item.image_id, !item.in_selection)}
            title={item.in_selection ? "Убрать из отбора" : "Добавить в отбор"}
          >
            {item.in_selection ? <Check size={14} /> : <Plus size={14} />}
            {item.in_selection ? "В отборе" : "В отбор"}
          </button>
          <span>{index + 1} / {items.length}</span>
          <button
            type="button"
            className="primary-button viewer-replace"
            disabled={!canReplace}
            onClick={() => onReplace(item.image_id)}
            title={item.placed && item.image_id !== currentId ? "Кадры поменяются местами" : "Поставить в ячейку (Enter)"}
          >
            {item.image_id === currentId ? "Сейчас в ячейке" : item.placed ? "Поменять местами" : "Заменить"}
          </button>
        </div>
        <button onClick={onClose} title="Закрыть (Esc)" aria-label="Закрыть просмотр">
          <X size={21} />
        </button>
      </header>
      <div className="viewer-stage">
        {!loaded && <LoaderCircle className="viewer-loader spin" size={27} />}
        <img
          src={window.ailbum.originalUrl(item.image_id)}
          alt=""
          onLoad={() => setLoaded(true)}
          onClick={(event) => event.stopPropagation()}
        />
        <button
          className="viewer-arrow previous"
          onClick={(event) => { event.stopPropagation(); if (previous) setImageId(previous.image_id); }}
          disabled={!previous}
          aria-label="Предыдущий кадр"
        >
          <ChevronLeft size={28} />
        </button>
        <button
          className="viewer-arrow next"
          onClick={(event) => { event.stopPropagation(); if (next) setImageId(next.image_id); }}
          disabled={!next}
          aria-label="Следующий кадр"
        >
          <ChevronRight size={28} />
        </button>
      </div>
      {items.length > 1 && (
        <div className="viewer-strip" onClick={(event) => event.stopPropagation()}>
          {items.map((entry) => (
            <button
              key={entry.image_id}
              type="button"
              className={[
                entry.image_id === item.image_id ? "active" : "",
                entry.image_id === currentId ? "current" : "",
              ].join(" ")}
              onClick={() => setImageId(entry.image_id)}
            >
              <img src={window.ailbum.mediaUrl(entry.image_id)} alt="" loading="lazy" decoding="async" />
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
