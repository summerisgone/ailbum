import { LoaderCircle } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type { LayoutPreflight } from "../types";

export type WizardParams = {
  orientation: "vertical" | "horizontal";
  spread_count: number;
  min_photos: number;
  max_photos: number;
  assistant: "auto" | "off";
};

type Props = {
  runId: string;
  busy: boolean;
  replacing: boolean;
  onCreate(params: WizardParams): void;
  onCancel?(): void;
  onError(message: string): void;
};

function parseCount(value: string): number {
  return /^\d+$/.test(value.trim()) ? Number(value) : Number.NaN;
}

export function LayoutWizard({ runId, busy, replacing, onCreate, onCancel, onError }: Props) {
  const [orientation, setOrientation] = useState<WizardParams["orientation"]>("vertical");
  const [spreads, setSpreads] = useState("4");
  const [minPhotos, setMinPhotos] = useState("3");
  const [maxPhotos, setMaxPhotos] = useState("6");
  const [assistant, setAssistant] = useState<WizardParams["assistant"]>("auto");
  const [preflight, setPreflight] = useState<LayoutPreflight | null>(null);
  const [loading, setLoading] = useState(false);
  const requestId = useRef(0);

  const spreadCount = parseCount(spreads);
  const min = parseCount(minPhotos);
  const max = parseCount(maxPhotos);
  const inputValid = [spreadCount, min, max].every(Number.isFinite);

  useEffect(() => {
    const id = ++requestId.current;
    if (!inputValid) {
      setPreflight(null);
      setLoading(false);
      return;
    }
    setLoading(true);
    const timer = window.setTimeout(() => {
      window.ailbum
        .layoutPreflight(runId, { orientation, spread_count: spreadCount, min_photos: min, max_photos: max })
        .then((result) => {
          if (id !== requestId.current) return;
          setPreflight(result);
          setLoading(false);
        })
        .catch((reason) => {
          if (id !== requestId.current) return;
          setLoading(false);
          onError(String(reason));
        });
    }, 250);
    return () => window.clearTimeout(timer);
  }, [runId, orientation, spreadCount, min, max, inputValid, onError]);

  const hint = preflight ? Math.max(1, Math.floor(preflight.unit_count / 4)) : null;
  const errors = !inputValid ? ["Введите целые числа"] : preflight?.errors ?? [];
  const ready = inputValid && !loading && preflight != null && preflight.errors.length === 0 && !busy;

  const create = () => {
    if (!ready) return;
    onCreate({ orientation, spread_count: spreadCount, min_photos: min, max_photos: max, assistant });
  };

  return (
    <div className="layout-wizard">
      <section className="layout-step">
        <span className="layout-step-number">1</span>
        <h3>Ориентация</h3>
        <div className="layout-orientation">
          {(["vertical", "horizontal"] as const).map((value) => (
            <button
              key={value}
              className={`layout-card${orientation === value ? " active" : ""}`}
              onClick={() => setOrientation(value)}
            >
              <span className={`layout-card-page ${value}`} />
              <strong>{value === "vertical" ? "Вертикальная" : "Горизонтальная"}</strong>
              <small>{value === "vertical" ? "210 x 297 мм" : "297 x 210 мм"}</small>
            </button>
          ))}
        </div>
      </section>

      <section className="layout-step">
        <span className="layout-step-number">2</span>
        <h3>Число разворотов</h3>
        <input
          className="layout-input"
          inputMode="numeric"
          value={spreads}
          onChange={(event) => setSpreads(event.target.value)}
          aria-label="Число разворотов"
        />
        {hint != null && (
          <button className="layout-hint" onClick={() => setSpreads(String(hint))}>
            Подсказка: {hint}
          </button>
        )}
      </section>

      <section className="layout-step">
        <span className="layout-step-number">3</span>
        <h3>Фото на коллаже</h3>
        <div className="layout-range">
          <input
            className="layout-input"
            inputMode="numeric"
            value={minPhotos}
            onChange={(event) => setMinPhotos(event.target.value)}
            aria-label="Минимум фото"
          />
          <span>-</span>
          <input
            className="layout-input"
            inputMode="numeric"
            value={maxPhotos}
            onChange={(event) => setMaxPhotos(event.target.value)}
            aria-label="Максимум фото"
          />
        </div>
        <label className="layout-assistant">
          <span>AI-редактор</span>
          <select value={assistant} onChange={(event) => setAssistant(event.target.value as WizardParams["assistant"])}>
            <option value="auto">Авто</option>
            <option value="off">Выключен</option>
          </select>
        </label>
      </section>

      <section className="layout-summary">
        <div className="layout-summary-line">
          {loading && <LoaderCircle size={14} className="layout-spin" />}
          {preflight ? (
            <strong>
              {preflight.unit_count} кадров, {preflight.story_count} сюжетов, нужно {preflight.min_needed}-{preflight.max_used}
            </strong>
          ) : (
            <strong>Расчёт...</strong>
          )}
        </div>
        {errors.length > 0 && (
          <ul className="layout-errors">
            {errors.map((text, index) => <li key={index}>{text}</li>)}
          </ul>
        )}
        {inputValid && preflight && preflight.warnings.length > 0 && (
          <ul className="layout-warnings">
            {preflight.warnings.map((text, index) => <li key={index}>{text}</li>)}
          </ul>
        )}
        {inputValid && preflight && preflight.allocation.length > 0 && (
          <ul className="layout-allocation">
            {preflight.allocation.map((item, index) => (
              <li key={`${item.story_ids.join("-")}-${index}`}>
                <span>{item.title}</span>
                <small>{item.units} кадров</small>
                <b>{item.spreads}</b>
              </li>
            ))}
          </ul>
        )}
        <div className="layout-actions">
          {onCancel && <button className="layout-secondary" onClick={onCancel}>Отмена</button>}
          <button className="primary-button" disabled={!ready} onClick={create}>
            {replacing ? "Создать заново" : "Создать"}
          </button>
        </div>
      </section>
    </div>
  );
}
