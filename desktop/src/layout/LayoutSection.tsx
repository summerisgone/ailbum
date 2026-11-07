import { LoaderCircle } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import type { DatabaseJob, Layout } from "../types";
import { LayoutEditor } from "./LayoutEditor";
import { LayoutWizard, type WizardParams } from "./LayoutWizard";
import "./layout.css";

type Props = {
  runId: string;
  onError(message: string): void;
};

export function LayoutSection({ runId, onError }: Props) {
  const [layout, setLayout] = useState<Layout | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [wizardOpen, setWizardOpen] = useState(false);
  const [job, setJob] = useState<DatabaseJob>({ status: "idle" });
  const loadId = useRef(0);

  const load = useCallback(() => {
    const id = ++loadId.current;
    window.ailbum
      .getLayout(runId)
      .then((next) => {
        if (id !== loadId.current) return;
        setLayout(next);
        setLoaded(true);
        if (next) setWizardOpen(false);
      })
      .catch((reason) => {
        if (id !== loadId.current) return;
        setLoaded(true);
        onError(String(reason));
      });
  }, [runId, onError]);

  useEffect(() => {
    setLoaded(false);
    setLayout(null);
    setWizardOpen(false);
    load();
  }, [load]);

  useEffect(() => {
    window.ailbum.getDatabaseJob().then(setJob).catch(() => undefined);
    return window.ailbum.onDatabaseJob(setJob);
  }, []);

  useEffect(() => {
    if (job.status === "complete" && job.kind === "layout") load();
  }, [job.status, job.kind, load]);

  const running = job.status === "running";
  const layoutRunning = running && job.kind === "layout";

  const create = async (params: WizardParams) => {
    try {
      setJob(await window.ailbum.startLayout(runId, params));
    } catch (reason) {
      onError(String(reason));
    }
  };

  const onChange = useCallback((next: Layout) => setLayout(next), []);
  const onRecreate = useCallback(() => setWizardOpen(true), []);

  if (!loaded) {
    return <div className="layout-section"><div className="layout-loading"><LoaderCircle className="layout-spin" size={22} /></div></div>;
  }

  const progress = layoutRunning && job.total ? Math.min(100, ((job.current ?? 0) / job.total) * 100) : null;

  return (
    <div className="layout-section">
      {running && (
        <div className="layout-job">
          <LoaderCircle size={15} className="layout-spin" />
          <strong>{layoutRunning ? job.stage || "Создание раскладки" : "Идёт анализ, раскладка недоступна"}</strong>
          {layoutRunning && job.detail && <small>{job.detail}</small>}
          {layoutRunning && (
            <div className={`layout-progress${progress == null ? " indeterminate" : ""}`}>
              <span style={progress == null ? undefined : { width: `${progress}%` }} />
            </div>
          )}
        </div>
      )}
      {job.status === "error" && job.kind === "layout" && job.error && (
        <div className="layout-job error">{job.error}</div>
      )}
      {layout && !wizardOpen ? (
        <LayoutEditor layout={layout} onChange={onChange} onRecreate={onRecreate} onError={onError} />
      ) : (
        <div className="layout-wizard-wrap">
          <header className="layout-heading">
            <h2>Создать раскладку</h2>
            {layout && <p>Новая раскладка заменит текущую.</p>}
          </header>
          <LayoutWizard
            runId={runId}
            busy={running}
            replacing={layout != null}
            onCreate={create}
            onCancel={layout ? () => setWizardOpen(false) : undefined}
            onError={onError}
          />
        </div>
      )}
    </div>
  );
}
