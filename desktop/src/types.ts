export type Photo = {
  id: number;
  path: string;
  file_name: string;
  width: number | null;
  height: number | null;
  orientation: number | null;
  taken_at: string | null;
  modified_at: string;
  quality: number | null;
  sharpness: number | null;
  exposure: number | null;
  aesthetic_score: number | null;
  composition_score: number | null;
  rule_of_thirds: number | null;
  frame_occupancy: number | null;
  negative_space: number | null;
  crop_risk: number | null;
  color_balance: number | null;
  color_harmony: number | null;
  main_subject: {
    bbox: [number, number, number, number];
    center: [number, number];
    source: string;
  } | null;
  scene_tags: Array<{ label: string; confidence: number }>;
  object_tags: Array<{ label: string; confidence: number }>;
  is_blurry: boolean;
  similar_cluster: number | null;
  story_id: number | null;
  story_title: string | null;
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

export type Story = {
  id: number;
  title: string;
  started_at: string | null;
  ended_at: string | null;
  representative_image_id: number | null;
  photo_count: number;
  naming_model: string | null;
};

export type Library = {
  database: string;
  run: AnalysisRun | null;
  target_count: number;
  selected_count: number;
  stories: Story[];
  photos: Photo[];
};

export type DatabaseSummary = {
  images: number;
  available: number;
  unique_files: number;
  bytes: number;
  with_gps: number;
  with_taken_at: number;
  analysis_runs: number;
  faces: number;
  linked_faces: number;
  people: number;
  stories: number;
};

export type DatabaseJob = {
  status: "idle" | "running" | "complete" | "error" | "cancelled";
  kind?: "index" | "analyze";
  stage?: string;
  detail?: string;
  current?: number | null;
  total?: number | null;
  error?: string | null;
  result?: unknown;
};

export type FavoriteResult = {
  run_id: string;
  image_id: number;
  favorite: boolean;
  selected_count: number;
};

export type PersonSummary = {
  id: number;
  public_id: string;
  name: string | null;
  embedding_model: string;
  face_count: number;
  photo_count: number;
  cover_face_id: number | null;
};

export type Face = {
  id: number;
  run_id: string;
  face_id: string;
  face_index: number;
  image_id: number;
  bbox_x: number;
  bbox_y: number;
  bbox_width: number;
  bbox_height: number;
  confidence: number;
  person_id: number | null;
  embedding_model: string | null;
  left_eye_state: "open" | "closed" | null;
  right_eye_state: "open" | "closed" | null;
  both_eyes_open: boolean | null;
  expression: string | null;
  expression_confidence: number | null;
  smile_probability: number | null;
  path: string;
  file_name: string;
  taken_at: string | null;
  orientation: number | null;
};

export type PeopleLibrary = {
  database: string;
  people: PersonSummary[];
  unassigned_count: number;
  total_faces: number;
};

export type FaceCollection = {
  person: Pick<PersonSummary, "id" | "public_id" | "name" | "embedding_model"> | null;
  faces: Face[];
};

declare global {
  interface Window {
    ailbum: {
      platform: string;
      bootstrap(): Promise<Library>;
      setFavorite(runId: string, imageId: number, favorite: boolean): Promise<FavoriteResult>;
      setTarget(runId: string, targetCount: number): Promise<{ target_count: number }>;
      getPeople(): Promise<PeopleLibrary>;
      getFaces(personId: number | null): Promise<FaceCollection>;
      setPersonName(personId: number, name: string): Promise<unknown>;
      assignFace(faceId: number, personId: number | null): Promise<unknown>;
      createPersonFromFace(faceId: number, name: string): Promise<{ id: number }>;
      chooseDatabase(): Promise<Library | null>;
      createDatabase(): Promise<Library | null>;
      getDatabaseSummary(): Promise<DatabaseSummary>;
      choosePhotoFolders(): Promise<string[]>;
      pathForFile(file: File): string;
      startDatabaseJob(kind: "index" | "analyze", sources?: string[]): Promise<DatabaseJob>;
      getDatabaseJob(): Promise<DatabaseJob>;
      cancelDatabaseJob(): Promise<DatabaseJob>;
      onDatabaseJob(listener: (job: DatabaseJob) => void): () => void;
      mediaUrl(imageId: number): string;
      originalUrl(imageId: number): string;
      faceUrl(faceId: number): string;
    };
  }
}
