import { ChevronLeft, ChevronRight, Minus, Plus, X } from "lucide-react";
import { useEffect, useState } from "react";
import type { Layout } from "../types";
import { type Spread, imageStyle } from "./SpreadView";

type Mode = "book" | "actual";
type Props = { layout: Layout; mode: Mode; startSpread: number; onClose(): void };

const COVER_MM = 4;
const EDGE_MM = 3;
const CARD_W_MM = 85.6;
const CARD_H_MM = 53.98;
const SCALE_KEY = "ailbum.layout.pxPerMm";
// CSS pixels per millimetre: Mac screens are about 127 points per inch, others assume 96 dpi.
const DEFAULT_PX_PER_MM = (window.ailbum.platform === "darwin" ? 127 : 96) / 25.4;

function savedScale(): number {
  try {
    const value = Number(localStorage.getItem(SCALE_KEY));
    return value > 1 && value < 20 ? value : DEFAULT_PX_PER_MM;
  } catch {
    return DEFAULT_PX_PER_MM;
  }
}

function useViewport() {
  const [size, setSize] = useState({ w: window.innerWidth, h: window.innerHeight });
  useEffect(() => {
    const onResize = () => setSize({ w: window.innerWidth, h: window.innerHeight });
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);
  return size;
}

// The spread as printed: bleed trimmed off, `scale` CSS pixels per millimetre.
function SpreadPicture({ spread, format, scale }: { spread: Spread; format: Layout["format"]; scale: number }) {
  const bleed = format.bleed_mm * scale;
  return (
    <div
      className="print-spread"
      style={{ width: (format.spread_w_mm - 2 * format.bleed_mm) * scale, height: (format.spread_h_mm - 2 * format.bleed_mm) * scale }}
    >
      <div
        className="print-bleed"
        style={{ left: -bleed, top: -bleed, width: format.spread_w_mm * scale, height: format.spread_h_mm * scale }}
      >
        {spread.cells.map((cell) => (
          <div
            key={cell.index}
            className="print-cell"
            style={{ left: `${cell.x * 100}%`, top: `${cell.y * 100}%`, width: `${cell.w * 100}%`, height: `${cell.h * 100}%` }}
          >
            {cell.placement && (
              <img
                src={window.ailbum.originalUrl(cell.placement.image_id)}
                alt=""
                decoding="async"
                draggable={false}
                style={imageStyle(cell.placement.crop)}
                onError={(event) => {
                  const fallback = window.ailbum.mediaUrl(cell.placement!.image_id);
                  if (event.currentTarget.src !== fallback) event.currentTarget.src = fallback;
                }}
              />
            )}
          </div>
        ))}
      </div>
    </div>
  );
}

export function AlbumPreview({ layout, mode, startSpread, onClose }: Props) {
  const spreads = layout.spreads;
  const book = mode === "book";
  // Book pages: 0 is the front cover, 1..n the spreads, n + 1 the back cover.
  const last = book ? spreads.length + 1 : spreads.length - 1;
  const [page, setPage] = useState(book ? startSpread + 1 : startSpread);
  const [pxPerMm, setPxPerMm] = useState(savedScale);
  const [calibrating, setCalibrating] = useState(false);
  const viewport = useViewport();
  const { format } = layout;
  const trimW = format.spread_w_mm - 2 * format.bleed_mm;
  const trimH = format.spread_h_mm - 2 * format.bleed_mm;

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
      else if (event.key === "ArrowLeft") setPage((value) => Math.max(0, value - 1));
      else if (event.key === "ArrowRight") setPage((value) => Math.min(last, value + 1));
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [last, onClose]);

  function changeScale(factor: number) {
    const next = Math.min(19, Math.max(1.5, pxPerMm * factor));
    setPxPerMm(next);
    try {
      localStorage.setItem(SCALE_KEY, String(next));
    } catch {
      // Calibration then lasts only for this session.
    }
  }

  const fit = Math.min(
    (viewport.w - 180) / (trimW + 2 * (COVER_MM + EDGE_MM)),
    (viewport.h - 190) / (trimH + 2 * COVER_MM),
  );
  const spread = book ? spreads[page - 1] : spreads[page];
  const title = book
    ? page === 0
      ? "Обложка"
      : page === last
        ? "Задняя обложка"
        : `Разворот ${page} из ${spreads.length}`
    : `Разворот ${page + 1} из ${spreads.length}`;

  return (
    <div className="album-preview" role="dialog" aria-modal="true" aria-label="Предпросмотр альбома">
      <header className="album-preview-head">
        <div>
          <strong>{book ? "Альбом" : "Натуральная величина"}</strong>
          <span>
            {title}
            {spread?.story_title ? ` · ${spread.story_title}` : ""}
          </span>
        </div>
        {!book && (
          <div className="album-scale">
            <button type="button" onClick={() => setCalibrating((value) => !value)} className={calibrating ? "on" : ""}>
              Калибровка
            </button>
            {calibrating && (
              <>
                <button type="button" aria-label="Меньше" onClick={() => changeScale(1 / 1.01)}>
                  <Minus size={13} />
                </button>
                <button type="button" aria-label="Больше" onClick={() => changeScale(1.01)}>
                  <Plus size={13} />
                </button>
              </>
            )}
          </div>
        )}
        <button type="button" className="album-close" onClick={onClose} aria-label="Закрыть (Esc)">
          <X size={20} />
        </button>
      </header>

      {!book && calibrating && (
        <div className="album-calibration">
          <span className="album-card" style={{ width: CARD_W_MM * pxPerMm, height: CARD_H_MM * pxPerMm }} />
          <p>Приложите банковскую карту к рамке и подгоните кнопками - и + до совпадения. Масштаб запомнится.</p>
        </div>
      )}

      <div className={book ? "album-stage" : "album-stage actual"}>
        {book && page === 0 && (
          <div className="book-cover" style={{ width: (trimW / 2 + COVER_MM) * fit, height: (trimH + 2 * COVER_MM) * fit }}>
            <span className="book-cover-title">Альбом</span>
            {spreads[0]?.story_title && <span className="book-cover-subtitle">{spreads[0].story_title}</span>}
          </div>
        )}
        {book && page === last && (
          <div className="book-cover back" style={{ width: (trimW / 2 + COVER_MM) * fit, height: (trimH + 2 * COVER_MM) * fit }} />
        )}
        {book && spread && (
          <div className="book-open" style={{ padding: COVER_MM * fit }}>
            <div className="book-edge left" style={{ width: EDGE_MM * fit * ((page - 1) / Math.max(1, spreads.length - 1)) }} />
            <div className="book-pages">
              <SpreadPicture spread={spread} format={format} scale={fit} />
              <div className="book-gutter" />
            </div>
            <div className="book-edge right" style={{ width: EDGE_MM * fit * ((spreads.length - page) / Math.max(1, spreads.length - 1)) }} />
          </div>
        )}
        {!book && spread && (
          <div className="album-actual">
            <SpreadPicture spread={spread} format={format} scale={pxPerMm} />
          </div>
        )}
      </div>

      <button
        type="button"
        className="viewer-arrow previous"
        disabled={page === 0}
        onClick={() => setPage((value) => Math.max(0, value - 1))}
        aria-label="Назад"
      >
        <ChevronLeft size={28} />
      </button>
      <button
        type="button"
        className="viewer-arrow next"
        disabled={page === last}
        onClick={() => setPage((value) => Math.min(last, value + 1))}
        aria-label="Вперёд"
      >
        <ChevronRight size={28} />
      </button>
    </div>
  );
}
