import { useRef, useState } from "react";
import type { Layout } from "../types";

export type Spread = Layout["spreads"][number];
export type SpreadCell = Spread["cells"][number];
export type Crop = { x: number; y: number; w: number; h: number };

export const WARNING_LABELS: Record<string, string> = {
  face_cut: "Лицо обрезано",
  face_on_spine: "Лицо на корешке",
  merged_stories: "Объединены сюжеты",
  underfilled: "Мало кадров",
};

const SPINE_GUARD_MM = 8;

const clamp = (value: number, low: number, high: number) => Math.min(high, Math.max(low, value));

// Keep the window inside the photo; a degenerate size falls back to the whole frame.
export function normalizeCrop(crop: Crop): Crop {
  const w = crop.w > 0 && crop.w <= 1 ? crop.w : 1;
  const h = crop.h > 0 && crop.h <= 1 ? crop.h : 1;
  return { x: clamp(crop.x, 0, 1 - w), y: clamp(crop.y, 0, 1 - h), w, h };
}

// Dragging by (dx, dy) cell fractions moves the window the opposite way; size is untouched.
export function dragCrop(start: Crop, dx: number, dy: number): Crop {
  const c = normalizeCrop(start);
  return normalizeCrop({ ...c, x: c.x - dx * c.w, y: c.y - dy * c.h });
}

export function imageStyle(crop: Crop) {
  const c = normalizeCrop(crop);
  return {
    width: `${100 / c.w}%`,
    height: `${100 / c.h}%`,
    left: `${(-c.x * 100) / c.w}%`,
    top: `${(-c.y * 100) / c.h}%`,
  };
}

type Props = {
  spread: Spread;
  format: Layout["format"];
  guides: boolean;
  selectedCell: number | null;
  busy: boolean;
  onSelect(cellIndex: number): void;
  onCrop(cellIndex: number, crop: Crop): void;
  onSwap(cellA: number, cellB: number): void;
};

type DragState = { cell: number; startX: number; startY: number; w: number; h: number; crop: Crop };

export function SpreadView({ spread, format, guides, selectedCell, busy, onSelect, onCrop, onSwap }: Props) {
  const drag = useRef<DragState | null>(null);
  const moved = useRef(false);
  const [draft, setDraft] = useState<{ cell: number; crop: Crop } | null>(null);
  const [dropTarget, setDropTarget] = useState<number | null>(null);

  const pct = (mm: number, total: number) => `${(mm / total) * 100}%`;
  const inset = format.bleed_mm + format.safe_mm;

  function down(event: React.PointerEvent<HTMLDivElement>, cell: SpreadCell) {
    if (busy || !cell.placement) return;
    const box = event.currentTarget.getBoundingClientRect();
    if (box.width <= 0 || box.height <= 0) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    moved.current = false;
    drag.current = {
      cell: cell.index,
      startX: event.clientX,
      startY: event.clientY,
      w: box.width,
      h: box.height,
      crop: cell.placement.crop,
    };
  }

  function move(event: React.PointerEvent<HTMLDivElement>) {
    const state = drag.current;
    if (!state) return;
    const dx = (event.clientX - state.startX) / state.w;
    const dy = (event.clientY - state.startY) / state.h;
    if (Math.abs(dx) + Math.abs(dy) > 0.005) moved.current = true;
    setDraft({ cell: state.cell, crop: dragCrop(state.crop, dx, dy) });
  }

  // The crop is persisted only here, not while moving.
  function up(event: React.PointerEvent<HTMLDivElement>) {
    const state = drag.current;
    drag.current = null;
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
    if (!state) return;
    const dx = (event.clientX - state.startX) / state.w;
    const dy = (event.clientY - state.startY) / state.h;
    setDraft(null);
    if (moved.current) onCrop(state.cell, dragCrop(state.crop, dx, dy));
    else onSelect(state.cell);
  }

  function cancel() {
    drag.current = null;
    setDraft(null);
  }

  return (
    <div className="spread-frame" style={{ aspectRatio: `${format.spread_w_mm} / ${format.spread_h_mm}` }}>
      {spread.cells.map((cell) => {
        const placement = cell.placement;
        const crop = draft && draft.cell === cell.index ? draft.crop : placement?.crop;
        const warnings = placement?.warnings ?? [];
        return (
          <div
            key={cell.index}
            className={[
              "spread-cell",
              selectedCell === cell.index ? "selected" : "",
              dropTarget === cell.index ? "drop" : "",
            ].join(" ")}
            style={{
              left: `${cell.x * 100}%`,
              top: `${cell.y * 100}%`,
              width: `${cell.w * 100}%`,
              height: `${cell.h * 100}%`,
            }}
            onPointerDown={(event) => down(event, cell)}
            onPointerMove={move}
            onPointerUp={up}
            onPointerCancel={cancel}
            onDragOver={(event) => {
              if (busy) return;
              event.preventDefault();
              setDropTarget(cell.index);
            }}
            onDragLeave={() => setDropTarget(null)}
            onDrop={(event) => {
              event.preventDefault();
              setDropTarget(null);
              const from = Number(event.dataTransfer.getData("text/x-ailbum-cell"));
              const origin = event.dataTransfer.getData("text/x-ailbum-spread");
              if (origin === String(spread.id) && Number.isInteger(from) && from !== cell.index) {
                onSwap(from, cell.index);
              }
            }}
          >
            {placement && crop && (
              <img
                className="spread-photo"
                src={window.ailbum.mediaUrl(placement.image_id)}
                alt=""
                draggable={false}
                style={imageStyle(crop)}
              />
            )}
            {!placement && <span className="spread-empty">Пусто</span>}
            {placement && (
              <span
                className="swap-grip"
                title="Перетащите на другую ячейку, чтобы поменять кадры"
                draggable={!busy}
                onPointerDown={(event) => event.stopPropagation()}
                onDragStart={(event) => {
                  event.dataTransfer.setData("text/x-ailbum-cell", String(cell.index));
                  event.dataTransfer.setData("text/x-ailbum-spread", String(spread.id));
                  event.dataTransfer.effectAllowed = "move";
                }}
              >
                ⇄
              </span>
            )}
            {placement?.replaced_image_id != null && <span className="cell-badge similar">Из похожих</span>}
            {warnings.length > 0 && (
              <span className="cell-badge warn" title={warnings.map((w) => WARNING_LABELS[w] ?? w).join(", ")}>
                {warnings.map((w) => WARNING_LABELS[w] ?? w).join(", ")}
              </span>
            )}
          </div>
        );
      })}
      {guides && (
        <div className="spread-guides" aria-hidden="true">
          <div
            className="guide bleed"
            style={{
              left: pct(format.bleed_mm, format.spread_w_mm),
              right: pct(format.bleed_mm, format.spread_w_mm),
              top: pct(format.bleed_mm, format.spread_h_mm),
              bottom: pct(format.bleed_mm, format.spread_h_mm),
            }}
          />
          <div
            className="guide safe"
            style={{
              left: pct(inset, format.spread_w_mm),
              right: pct(inset, format.spread_w_mm),
              top: pct(inset, format.spread_h_mm),
              bottom: pct(inset, format.spread_h_mm),
            }}
          />
          <div
            className="guide spine"
            style={{
              left: pct(format.spread_w_mm / 2 - SPINE_GUARD_MM, format.spread_w_mm),
              width: pct(SPINE_GUARD_MM * 2, format.spread_w_mm),
            }}
          />
        </div>
      )}
    </div>
  );
}
