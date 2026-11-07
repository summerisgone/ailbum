import { useEffect, useState } from "react";

// What the picker understood from a wish, refreshed shortly after typing stops.
export function usePromptLabels(prompt: string): string[] {
  const [labels, setLabels] = useState<string[]>([]);
  useEffect(() => {
    if (!prompt.trim()) {
      setLabels([]);
      return;
    }
    let live = true;
    const timer = window.setTimeout(() => {
      window.ailbum
        .parseLayoutPrompt(prompt)
        .then((info) => {
          if (live) setLabels(info.labels);
        })
        .catch(() => {
          if (live) setLabels([]);
        });
    }, 250);
    return () => {
      live = false;
      window.clearTimeout(timer);
    };
  }, [prompt]);
  return labels;
}
