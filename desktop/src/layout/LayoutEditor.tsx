import { BookOpen, Check, FolderDown, Images, Maximize2, Minus, Plus, Ruler } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type { Layout, LayoutAlternative, LayoutVariant } from "../types";
import { AlbumPreview } from "./AlbumPreview";
import { LayoutViewer, placedLabel } from "./LayoutViewer";
import { type Crop, MAX_ZOOM, SpreadView, WARNING_LABELS, imageStyle, zoomCrop, zoomOf } from "./SpreadView";
import { usePromptLabels } from "./usePromptLabels";
import "./editor.css";

type Props = {
  layout: Layout;
  onChange(layout: Layout): void;
  onRecreate(): void;
  onError(message: string): void;
  onOpenPhotos(storyId: number | null): void;
  onSetFavorite(imageId: number, favorite: boolean): Promise<void>;
  readOnly?: boolean;
};

type Viewer = { title: string; items: LayoutAlternative[]; startId: number; source: "similar" | "candidates" };

const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));
const ZOOM_STEP = 1.25;

export function LayoutEditor({ layout, onChange, onRecreate, onError, onOpenPhotos, onSetFavorite, readOnly = false }: Props) {
  const [selected, setSelected] = useState<{ spreadId: number; cell: number } | null>(null);
  const [guides, setGuides] = useState(true);
  const [working, setBusy] = useState(false);
  const busy = working || readOnly;
  const [alternatives, setAlternatives] = useState<LayoutAlternative[]>([]);
  const [similar, setSimilar] = useState<LayoutAlternative[]>([]);
  const [variants, setVariants] = useState<LayoutVariant[]>([]);
  const [viewer, setViewer] = useState<Viewer | null>(null);
  const [prompt, setPrompt] = useState("");
  const [version, setVersion] = useState(0);
  const [preview, setPreview] = useState<"book" | "actual" | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const requestId = useRef(0);
  const labels = usePromptLabels(prompt);

  const spread = selected ? layout.spreads.find((item) => item.id === selected.spreadId) : undefined;
  const cell = spread && selected ? spread.cells.find((item) => item.index === selected.cell) : undefined;
  const placement = cell?.placement ?? null;
  const spreadId = spread?.id;
  const cellIndex = cell?.index;
  const placedId = placement?.image_id;
  const spreadKey = spread ? `${spread.template_id}:${spread.cells.map((c) => c.placement?.image_id).join(",")}` : "";

  useEffect(() => {
    if (spreadId === undefined || cellIndex === undefined) {
      setAlternatives([]);
      setSimilar([]);
      return;
    }
    const id = ++requestId.current;
    window.ailbum
      .getLayoutAlternatives(spreadId, cellIndex)
      .then((items) => {
        if (id === requestId.current) setAlternatives(items);
      })
      .catch((error) => onError(errorText(error)));
    if (placedId === undefined) {
      setSimilar([]);
      return;
    }
    window.ailbum
      .getLayoutSimilar(spreadId, cellIndex)
      .then((items) => {
        if (id === requestId.current) setSimilar(items);
      })
      .catch((error) => onError(errorText(error)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [spreadId, cellIndex, placedId, version]);

  useEffect(() => {
    if (spreadId === undefined) {
      setVariants([]);
      return;
    }
    let live = true;
    window.ailbum
      .getLayoutVariants(spreadId)
      .then((items) => {
        if (live) setVariants(items);
      })
      .catch((error) => onError(errorText(error)));
    return () => {
      live = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [spreadId, spreadKey, version]);

  async function edit(action: () => Promise<Layout>) {
    if (busy) return;
    setBusy(true);
    try {
      onChange(await action());
      setVersion((value) => value + 1);
    } catch (error) {
      onError(errorText(error));
    } finally {
      setBusy(false);
    }
  }

  async function toggleSelection(imageId: number, favorite: boolean) {
    if (busy) return;
    setBusy(true);
    try {
      await onSetFavorite(imageId, favorite);
      const next = await window.ailbum.getLayout(layout.album_id);
      if (next) onChange(next);
      setVersion((value) => value + 1);
    } catch (error) {
      onError(errorText(error));
    } finally {
      setBusy(false);
    }
  }

  function select(spreadIdValue: number, cellValue: number) {
    setSelected((current) =>
      current && current.spreadId === spreadIdValue && current.cell === cellValue
        ? null
        : { spreadId: spreadIdValue, cell: cellValue },
    );
  }

  async function openSimilar(spreadIdValue: number, cellValue: number) {
    const target = layout.spreads.find((item) => item.id === spreadIdValue)?.cells.find((c) => c.index === cellValue);
    if (!target?.placement) return;
    setSelected({ spreadId: spreadIdValue, cell: cellValue });
    try {
      const items = await window.ailbum.getLayoutSimilar(spreadIdValue, cellValue);
      setViewer({ title: "Похожие кадры", items, startId: target.placement.image_id, source: "similar" });
    } catch (error) {
      onError(errorText(error));
    }
  }

  async function exportOriginals() {
    if (working) return;
    setBusy(true);
    try {
      const result = await window.ailbum.exportLayout(layout.album_id);
      if (result) {
        setNotice(
          `Сохранено фото: ${result.count} в ${result.folder}` +
            (result.missing.length ? `. Не найдено файлов: ${result.missing.length}` : ""),
        );
      }
    } catch (error) {
      onError(errorText(error));
    } finally {
      setBusy(false);
    }
  }

  function zoom(factor: number | null) {
    if (!spread || !cell || !placement) return;
    const crop: Crop = factor == null ? zoomCrop(placement.crop, 1 / MAX_ZOOM) : zoomCrop(placement.crop, factor);
    edit(() => window.ailbum.setLayoutCrop(spread.id, cell.index, crop));
  }

  const viewerItems = viewer ? (viewer.source === "similar" ? similar : alternatives) : [];
  const zoomValue = placement ? zoomOf(placement.crop) : 1;
  const photoCount = spread?.cells.length ?? 0;

  return (
    <div className="layout-editor">
      <div className="layout-editor-main">
        {layout.stale && (
          <div className="layout-banner">
            <span>Выбор изменился, пересоздать?</span>
            <button type="button" disabled={readOnly} onClick={onRecreate}>
              Пересоздать
            </button>
          </div>
        )}
        {layout.warnings.length > 0 && (
          <div className="layout-banner info">
            {layout.warnings.map((warning) => WARNING_LABELS[warning] ?? warning).join("; ")}
          </div>
        )}
        {layout.unplaced.length > 0 && (
          <div className="layout-banner info">Не поместилось кадров: {layout.unplaced.length}</div>
        )}
        {notice && (
          <div className="layout-banner info">
            <span>{notice}</span>
            <button type="button" onClick={() => setNotice(null)}>Закрыть</button>
          </div>
        )}
        <div className="layout-toolbar">
          <label className="guides-toggle">
            <input type="checkbox" checked={guides} onChange={(event) => setGuides(event.target.checked)} />
            Направляющие
          </label>
          <button type="button" disabled={readOnly} onClick={onRecreate}>Новая раскладка</button>
          <button type="button" onClick={() => setPreview("book")}>
            <BookOpen size={13} /> Альбом
          </button>
          <button type="button" onClick={() => setPreview("actual")} title="Разворот в натуральную величину">
            <Ruler size={13} /> 1:1
          </button>
          <button type="button" disabled={working} onClick={exportOriginals}>
            <FolderDown size={13} /> Экспорт оригиналов
          </button>
          <span className="toolbar-hint">Колесо или щипок над выбранной ячейкой - масштаб, перетаскивание - кадрирование</span>
        </div>
        {layout.spreads.map((item) => (
          <section key={item.id} className="spread-section">
            <header className="spread-header">
              <strong>{item.story_title}</strong>
              <span>Разворот {item.position}</span>
              {item.warnings.map((warning) => (
                <span key={warning} className="cell-badge warn static">
                  {WARNING_LABELS[warning] ?? warning}
                </span>
              ))}
            </header>
            <SpreadView
              spread={item}
              format={layout.format}
              guides={guides}
              busy={busy}
              selectedCell={selected && selected.spreadId === item.id ? selected.cell : null}
              onSelect={(index) => select(item.id, index)}
              onCrop={(index, crop: Crop) => edit(() => window.ailbum.setLayoutCrop(item.id, index, crop))}
              onSwap={(a, b) => edit(() => window.ailbum.swapLayoutCells(item.id, a, b))}
              onOpen={(index) => openSimilar(item.id, index)}
            />
            {item.assistant_reason && <p className="spread-reason">{item.assistant_reason}</p>}
          </section>
        ))}
      </div>
      <aside className="layout-panel">
        {!spread || !cell ? (
          <p className="panel-empty">
            Выберите ячейку на развороте: здесь появятся варианты раскладки, масштаб и кандидаты на коллаж.
          </p>
        ) : (
          <>
            <section className="panel-section">
              <h3>Разворот {spread.position}</h3>
              {spread.story_title && <p className="panel-note muted">{spread.story_title}</p>}
              <h4>Варианты раскладки</h4>
              {variants.length === 0 ? (
                <p className="panel-note muted">Других вариантов нет</p>
              ) : (
                <div className="panel-variants">
                  {variants.map((variant) => (
                    <button
                      key={`${variant.template_id}:${variant.image_ids.join(",")}`}
                      type="button"
                      disabled={busy}
                      title="Заменить текущую раскладку разворота"
                      onClick={() =>
                        edit(() => window.ailbum.applyLayoutVariant(spread.id, variant.template_id, variant.image_ids))
                      }
                    >
                      <VariantThumb variant={variant} format={layout.format} />
                      <span>
                        {variant.image_ids.length === photoCount
                          ? `${photoCount} фото`
                          : variant.image_ids.length > photoCount
                            ? `${variant.image_ids.length} фото, +1 кадр`
                            : `${variant.image_ids.length} фото, без 1 кадра`}
                      </span>
                    </button>
                  ))}
                </div>
              )}
              <button type="button" disabled={busy} onClick={() => edit(() => window.ailbum.recomposeLayoutSpread(spread.id))}>
                Пересобрать разворот
              </button>
              <h4>Пожелание сборщику</h4>
              <textarea
                className="panel-prompt"
                rows={2}
                value={prompt}
                placeholder="Например: приоритет лицам и крупным планам"
                onChange={(event) => setPrompt(event.target.value)}
              />
              {prompt.trim() && (
                <p className={`panel-note${labels.length ? "" : " warn"}`}>
                  {labels.length ? `Понято: ${labels.join(", ")}` : "Не понято: укажите лица, крупные планы или пейзажи"}
                </p>
              )}
              <button
                type="button"
                disabled={busy || labels.length === 0}
                onClick={() => edit(() => window.ailbum.recomposeLayoutSpread(spread.id, prompt))}
              >
                Пересобрать с пожеланием
              </button>
            </section>

            <section className="panel-section">
              <h3>Ячейка {cell.index + 1}</h3>
              {placement?.replaced_image_id != null && <p className="panel-note">Заменено похожим кадром</p>}
              {placement && (
                <>
                  <button type="button" disabled={busy} onClick={() => openSimilar(spread.id, cell.index)}>
                    <Maximize2 size={13} /> Увеличить и выбрать из похожих
                    {similar.length > 1 ? ` (${similar.length})` : ""}
                  </button>
                  <div className="panel-zoom">
                    <span>Масштаб</span>
                    <button type="button" aria-label="Уменьшить" disabled={busy || zoomValue <= 1.001} onClick={() => zoom(1 / ZOOM_STEP)}>
                      <Minus size={13} />
                    </button>
                    <b>x{zoomValue.toFixed(1)}</b>
                    <button type="button" aria-label="Увеличить" disabled={busy || zoomValue >= MAX_ZOOM - 0.01} onClick={() => zoom(ZOOM_STEP)}>
                      <Plus size={13} />
                    </button>
                    <button type="button" disabled={busy || zoomValue <= 1.001} onClick={() => zoom(null)}>
                      Сбросить
                    </button>
                  </div>
                </>
              )}
            </section>

            <section className="panel-section panel-candidates-section">
              <div className="panel-section-head">
                <h3>Кандидаты на коллаж</h3>
                <button type="button" onClick={() => onOpenPhotos(spread.story_ids[0] ?? null)} title="Добавить или убрать кадры в основном отборе">
                  <Images size={13} /> В отбор фото
                </button>
              </div>
              <p className="panel-note muted">Кадры сюжета для ячейки {cell.index + 1}. Клик - поставить в ячейку.</p>
              <div className="panel-candidates">
                {alternatives.map((item) => {
                  const where = placedLabel(item, spread.id, placedId ?? null);
                  return (
                    <div
                      key={item.image_id}
                      className={[
                        "candidate",
                        item.image_id === placedId ? "current" : "",
                        item.placed ? "placed" : "",
                      ].join(" ")}
                    >
                      <button
                        type="button"
                        className="candidate-pick"
                        disabled={busy || item.image_id === placedId}
                        title={item.placed ? "Поменять местами с этой ячейкой" : "Поставить в ячейку"}
                        onClick={() => edit(() => window.ailbum.setLayoutPhoto(spread.id, cell.index, item.image_id))}
                      >
                        <img src={window.ailbum.mediaUrl(item.image_id)} alt="" loading="lazy" decoding="async" />
                      </button>
                      {where && <span className="candidate-placed">{where}</span>}
                      <div className="candidate-meta">
                        <span>{Math.round(item.fit * 100)}%</span>
                        {item.similar && item.image_id !== placedId && <span className="cell-badge similar static">Похожий</span>}
                        {!item.in_selection && <span className="cell-badge muted static">Не в отборе</span>}
                      </div>
                      {item.warnings.length > 0 && (
                        <span className="cell-badge warn static">
                          {item.warnings.map((w) => WARNING_LABELS[w] ?? w).join(", ")}
                        </span>
                      )}
                      <div className="candidate-actions">
                        <button
                          type="button"
                          title="Открыть на весь экран"
                          aria-label="Открыть на весь экран"
                          onClick={() =>
                            setViewer({ title: "Кандидаты на коллаж", items: alternatives, startId: item.image_id, source: "candidates" })
                          }
                        >
                          <Maximize2 size={12} />
                        </button>
                        <button
                          type="button"
                          className={item.in_selection ? "on" : ""}
                          disabled={busy}
                          title={item.in_selection ? "Убрать из отбора" : "Добавить в отбор"}
                          aria-label={item.in_selection ? "Убрать из отбора" : "Добавить в отбор"}
                          onClick={() => toggleSelection(item.image_id, !item.in_selection)}
                        >
                          {item.in_selection ? <Check size={12} /> : <Plus size={12} />}
                        </button>
                      </div>
                    </div>
                  );
                })}
              </div>
            </section>
          </>
        )}
      </aside>
      {preview && (
        <AlbumPreview
          layout={layout}
          mode={preview}
          startSpread={Math.max(0, layout.spreads.findIndex((item) => item.id === spread?.id))}
          onClose={() => setPreview(null)}
        />
      )}
      {viewer && spread && cell && viewerItems.length > 0 && (
        <LayoutViewer
          title={viewer.title}
          items={viewerItems}
          startId={viewer.startId}
          currentId={placedId ?? null}
          spreadId={spread.id}
          busy={busy}
          onReplace={(imageId) => {
            setViewer(null);
            edit(() => window.ailbum.setLayoutPhoto(spread.id, cell.index, imageId));
          }}
          onToggleSelection={toggleSelection}
          onClose={() => setViewer(null)}
        />
      )}
    </div>
  );
}

function VariantThumb({ variant, format }: { variant: LayoutVariant; format: Layout["format"] }) {
  return (
    <span className="variant-thumb" style={{ aspectRatio: `${format.spread_w_mm} / ${format.spread_h_mm}` }}>
      {variant.cells.map((item) => (
        <span
          key={item.index}
          className="variant-cell"
          style={{ left: `${item.x * 100}%`, top: `${item.y * 100}%`, width: `${item.w * 100}%`, height: `${item.h * 100}%` }}
        >
          <img src={window.ailbum.mediaUrl(item.image_id)} alt="" draggable={false} style={imageStyle(item.crop)} />
        </span>
      ))}
    </span>
  );
}
