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
  kind?: "index" | "analyze" | "layout";
  stage?: string;
  detail?: string;
  current?: number | null;
  total?: number | null;
  error?: string | null;
  result?: unknown;
};

export type LayoutParams = {
  orientation: "vertical" | "horizontal";
  spread_count: number;
  min_photos: number;
  max_photos: number;
  assistant?: "auto" | "off";
  prompt?: string;
};

export type LayoutPreflight = {
  pool_count: number;
  unit_count: number;
  story_count: number;
  min_needed: number;
  max_used: number;
  allocation: { story_ids: number[]; title: string; spreads: number; units: number }[];
  errors: string[];
  warnings: string[];
};

export type LayoutTemplateInfo = {
  id: string;
  photo_count: number;
  cells: { index: number; x: number; y: number; w: number; h: number }[];
};

export type LayoutAlternative = {
  image_id: number;
  fit: number;
  warnings: string[];
  in_selection: boolean;
  placed: { spread_id: number; position: number; cell_index: number } | null;
  similar: boolean;
};

export type LayoutVariant = {
  template_id: string;
  score: number;
  image_ids: number[];
  cells: {
    index: number;
    x: number;
    y: number;
    w: number;
    h: number;
    image_id: number;
    crop: { x: number; y: number; w: number; h: number };
  }[];
};

export type LayoutPromptInfo = { weights: Record<string, number>; labels: string[] };

export type LayoutPlacement = {
  image_id: number;
  crop: { x: number; y: number; w: number; h: number };
  fit: number;
  warnings: string[];
  replaced_image_id: number | null;
};

export type LayoutCell = {
  index: number;
  x: number;
  y: number;
  w: number;
  h: number;
  crosses_spine: boolean;
  placement: LayoutPlacement | null;
};

export type LayoutSpread = {
  id: number;
  position: number;
  template_id: string;
  story_ids: number[];
  story_title: string;
  warnings: string[];
  assistant_reason: string | null;
  cells: LayoutCell[];
};

export type Layout = {
  id: number;
  run_id: string;
  orientation: "vertical" | "horizontal";
  spread_count: number;
  min_photos: number;
  max_photos: number;
  stale: boolean;
  assistant_model: string | null;
  warnings: string[];
  unplaced: { image_id: number; reason: string }[];
  format: { spread_w_mm: number; spread_h_mm: number; bleed_mm: number; safe_mm: number };
  spreads: LayoutSpread[];
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
      mergePerson(sourceId: number, targetId: number): Promise<unknown>;
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
      layoutPreflight(runId: string, params: LayoutParams): Promise<LayoutPreflight>;
      getLayout(runId: string): Promise<Layout | null>;
      getLayoutTemplates(orientation: string, photoCount: number): Promise<LayoutTemplateInfo[]>;
      startLayout(runId: string, params: LayoutParams): Promise<DatabaseJob>;
      getLayoutAlternatives(spreadId: number, cellIndex: number): Promise<LayoutAlternative[]>;
      setLayoutPhoto(spreadId: number, cellIndex: number, imageId: number): Promise<Layout>;
      swapLayoutCells(spreadId: number, cellA: number, cellB: number): Promise<Layout>;
      setLayoutTemplate(spreadId: number, templateId: string): Promise<Layout>;
      setLayoutCrop(
        spreadId: number,
        cellIndex: number,
        crop: { x: number; y: number; w: number; h: number },
      ): Promise<Layout>;
      recomposeLayoutSpread(spreadId: number, prompt?: string): Promise<Layout>;
      getLayoutSimilar(spreadId: number, cellIndex: number): Promise<LayoutAlternative[]>;
      getLayoutVariants(spreadId: number): Promise<LayoutVariant[]>;
      applyLayoutVariant(spreadId: number, templateId: string, imageIds: number[]): Promise<Layout>;
      parseLayoutPrompt(prompt: string): Promise<LayoutPromptInfo>;
      exportLayout(runId: string): Promise<{ folder: string; count: number; missing: string[] } | null>;
      mediaUrl(imageId: number): string;
      originalUrl(imageId: number): string;
      faceUrl(faceId: number): string;
    };
  }
}
