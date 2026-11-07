import { useEffect, useRef, useState } from "react";
import type { Layout } from "../types";
import { type Crop, SpreadView, WARNING_LABELS } from "./SpreadView";
import "./editor.css";

type Props = {
  layout: Layout;
  onChange(layout: Layout): void;
  onRecreate(): void;
  onError(message: string): void;
};

type Alternative = { image_id: number; fit: number; warnings: string[]; in_selection: boolean };
type TemplateInfo = { id: string; photo_count: number };

const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));

export function LayoutEditor({ layout, onChange, onRecreate, onError }: Props) {
  const [selected, setSelected] = useState<{ spreadId: number; cell: number } | null>(null);
  const [guides, setGuides] = useState(true);
  const [busy, setBusy] = useState(false);
  const [alternatives, setAlternatives] = useState<Alternative[]>([]);
  const [templates, setTemplates] = useState<TemplateInfo[]>([]);
  const requestId = useRef(0);

  const spread = selected ? layout.spreads.find((item) => item.id === selected.spreadId) : undefined;
  const cell = spread && selected ? spread.cells.find((item) => item.index === selected.cell) : undefined;
  const spreadId = spread?.id;
  const cellIndex = cell?.index;
  const photoCount = spread?.cells.length;

  useEffect(() => {
    if (spreadId === undefined || cellIndex === undefined || photoCount === undefined) {
      setAlternatives([]);
      setTemplates([]);
      return;
    }
    const id = ++requestId.current;
    setAlternatives([]);
    window.ailbum
      .getLayoutAlternatives(spreadId, cellIndex)
      .then((items) => {
        if (id === requestId.current) setAlternatives(items as Alternative[]);
      })
      .catch((error) => onError(errorText(error)));
    window.ailbum
      .getLayoutTemplates(layout.orientation, photoCount)
      .then((items) => {
        if (id === requestId.current) setTemplates(items as TemplateInfo[]);
      })
      .catch((error) => onError(errorText(error)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [spreadId, cellIndex, photoCount, layout.orientation]);

  async function edit(action: () => Promise<Layout>) {
    if (busy) return;
    setBusy(true);
    try {
      const next = await action();
      setSelected(null);
      onChange(next);
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

  const placement = cell?.placement ?? null;

  return (
    <div className="layout-editor">
      <div className="layout-editor-main">
        {layout.stale && (
          <div className="layout-banner">
            <span>Выбор изменился, пересоздать?</span>
            <button type="button" onClick={onRecreate}>
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
        <div className="layout-toolbar">
          <label className="guides-toggle">
            <input type="checkbox" checked={guides} onChange={(event) => setGuides(event.target.checked)} />
            Направляющие
          </label>
          <button type="button" onClick={onRecreate}>Новая раскладка</button>
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
            />
            {item.assistant_reason && <p className="spread-reason">{item.assistant_reason}</p>}
          </section>
        ))}
      </div>
      {spread && cell && (
        <aside className="layout-panel">
          <h3>
            Разворот {spread.position}, ячейка {cell.index + 1}
          </h3>
          {placement?.replaced_image_id != null && <p className="panel-note">Заменено похожим кадром</p>}
          <button type="button" disabled={busy} onClick={() => edit(() => window.ailbum.recomposeLayoutSpread(spread.id))}>
            Пересобрать разворот
          </button>
          <h4>Шаблон</h4>
          <div className="panel-templates">
            {templates
              .filter((item) => item.id !== spread.template_id)
              .map((item) => (
                <button
                  key={item.id}
                  type="button"
                  disabled={busy}
                  onClick={() => edit(() => window.ailbum.setLayoutTemplate(spread.id, item.id))}
                >
                  {item.id}
                </button>
              ))}
          </div>
          <h4>Кадры</h4>
          <div className="panel-candidates">
            {alternatives.map((item) => (
              <button
                key={item.image_id}
                type="button"
                disabled={busy || item.image_id === placement?.image_id}
                className={item.image_id === placement?.image_id ? "current" : ""}
                onClick={() => edit(() => window.ailbum.setLayoutPhoto(spread.id, cell.index, item.image_id))}
              >
                <img src={window.ailbum.mediaUrl(item.image_id)} alt="" loading="lazy" decoding="async" />
                <span>{Math.round(item.fit * 100)}%</span>
                {!item.in_selection && <span className="cell-badge similar static">Из похожих</span>}
                {item.warnings.length > 0 && (
                  <span className="cell-badge warn static">
                    {item.warnings.map((w) => WARNING_LABELS[w] ?? w).join(", ")}
                  </span>
                )}
              </button>
            ))}
          </div>
        </aside>
      )}
    </div>
  );
}
