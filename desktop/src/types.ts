export type Photo = {
  id: number;
  path: string;
  file_name: string;
  width: number | null;
  height: number | null;
  taken_at: string | null;
  modified_at: string;
  quality: number | null;
  sharpness: number | null;
  exposure: number | null;
  is_blurry: boolean;
  similar_cluster: number | null;
  auto_selected: boolean;
  face_count: number;
  people_count: number;
  closed_eyes_count: number;
  smiling_faces_count: number;
  people_names: string[];
  favorite: boolean;
  selection_position: number | null;
};

export type AnalysisRun = {
  id: string;
  source: string;
  started_at: string;
  completed_at: string;
  face_backend: string;
  summary: Record<string, unknown>;
};

export type Library = {
  database: string;
  run: AnalysisRun | null;
  target_count: number;
  selected_count: number;
  photos: Photo[];
};

export type FavoriteResult = {
  run_id: string;
  image_id: number;
  favorite: boolean;
  selected_count: number;
};

declare global {
  interface Window {
    ailbum: {
      bootstrap(): Promise<Library>;
      setFavorite(runId: string, imageId: number, favorite: boolean): Promise<FavoriteResult>;
      setTarget(runId: string, targetCount: number): Promise<{ target_count: number }>;
      chooseDatabase(): Promise<Library | null>;
      mediaUrl(imageId: number): string;
    };
  }
}
