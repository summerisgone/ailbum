
CREATE TABLE IF NOT EXISTS images (
    id INTEGER PRIMARY KEY,
    path TEXT NOT NULL UNIQUE,
    source_root TEXT NOT NULL,
    relative_path TEXT NOT NULL,
    file_name TEXT NOT NULL,
    extension TEXT NOT NULL,
    file_size_bytes INTEGER NOT NULL,
    modified_at TEXT NOT NULL,
    created_at TEXT,
    sha256 TEXT NOT NULL,
    mime_type TEXT,
    image_format TEXT,
    color_mode TEXT,
    width INTEGER,
    height INTEGER,
    frame_count INTEGER,
    orientation INTEGER,
    taken_at TEXT,
    camera_make TEXT,
    camera_model TEXT,
    lens_model TEXT,
    software TEXT,
    gps_latitude REAL,
    gps_longitude REAL,
    gps_altitude REAL,
    exif_json TEXT NOT NULL,
    container_metadata_json TEXT NOT NULL,
    extraction_error TEXT,
    indexed_at TEXT NOT NULL,
    availability TEXT NOT NULL DEFAULT 'present'
        CHECK (availability IN ('present', 'missing', 'archived'))
);

CREATE INDEX IF NOT EXISTS idx_images_sha256 ON images(sha256);
CREATE INDEX IF NOT EXISTS idx_images_taken_at ON images(taken_at);
CREATE INDEX IF NOT EXISTS idx_images_camera ON images(camera_make, camera_model);
CREATE INDEX IF NOT EXISTS idx_images_source_root ON images(source_root);

CREATE TABLE IF NOT EXISTS analysis_runs (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    output TEXT NOT NULL,
    started_at TEXT NOT NULL,
    completed_at TEXT NOT NULL,
    face_backend TEXT NOT NULL,
    config_json TEXT NOT NULL,
    summary_json TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('completed', 'failed'))
);

CREATE TABLE IF NOT EXISTS photo_analysis (
    run_id TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
    image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE RESTRICT,
    photo_id TEXT NOT NULL,
    sharpness REAL NOT NULL,
    exposure REAL NOT NULL,
    quality REAL NOT NULL,
    aesthetic_score REAL,
    composition_score REAL,
    rule_of_thirds REAL,
    frame_occupancy REAL,
    negative_space REAL,
    crop_risk REAL,
    color_balance REAL,
    color_harmony REAL,
    main_subject_json TEXT,
    scene_tags_json TEXT NOT NULL DEFAULT '[]',
    object_tags_json TEXT NOT NULL DEFAULT '[]',
    vision_embedding BLOB,
    vision_embedding_dim INTEGER,
    vision_embedding_model TEXT,
    is_blurry INTEGER NOT NULL CHECK (is_blurry IN (0, 1)),
    similar_cluster INTEGER,
    story_id INTEGER,
    selected INTEGER NOT NULL CHECK (selected IN (0, 1)),
    error TEXT,
    PRIMARY KEY (run_id, image_id),
    UNIQUE (run_id, photo_id)
);

CREATE INDEX IF NOT EXISTS idx_photo_analysis_selected ON photo_analysis(run_id, selected);
CREATE INDEX IF NOT EXISTS idx_photo_analysis_similar ON photo_analysis(run_id, similar_cluster);

CREATE TABLE IF NOT EXISTS stories (
    run_id TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
    story_id INTEGER NOT NULL,
    title TEXT NOT NULL,
    started_at TEXT,
    ended_at TEXT,
    representative_image_id INTEGER REFERENCES images(id) ON DELETE SET NULL,
    scene_tags_json TEXT NOT NULL DEFAULT '[]',
    object_tags_json TEXT NOT NULL DEFAULT '[]',
    naming_model TEXT,
    algorithm_version INTEGER NOT NULL DEFAULT 2,
    PRIMARY KEY (run_id, story_id)
);

CREATE INDEX IF NOT EXISTS idx_stories_time ON stories(run_id, started_at);

CREATE TABLE IF NOT EXISTS people (
    id INTEGER PRIMARY KEY,
    public_id TEXT NOT NULL UNIQUE,
    name TEXT,
    embedding_model TEXT NOT NULL,
    centroid_embedding BLOB NOT NULL,
    embedding_dim INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_people_name ON people(name);
CREATE INDEX IF NOT EXISTS idx_people_model ON people(embedding_model);

CREATE TABLE IF NOT EXISTS faces (
    id INTEGER PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
    image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE RESTRICT,
    face_id TEXT NOT NULL,
    face_index INTEGER NOT NULL,
    bbox_x INTEGER NOT NULL,
    bbox_y INTEGER NOT NULL,
    bbox_width INTEGER NOT NULL,
    bbox_height INTEGER NOT NULL,
    confidence REAL NOT NULL,
    person_cluster INTEGER,
    person_id INTEGER REFERENCES people(id) ON DELETE SET NULL,
    embedding BLOB,
    embedding_dim INTEGER,
    embedding_model TEXT,
    left_eye_state TEXT CHECK (left_eye_state IN ('open', 'closed') OR left_eye_state IS NULL),
    right_eye_state TEXT CHECK (right_eye_state IN ('open', 'closed') OR right_eye_state IS NULL),
    left_eye_open_probability REAL,
    right_eye_open_probability REAL,
    both_eyes_open INTEGER CHECK (both_eyes_open IN (0, 1) OR both_eyes_open IS NULL),
    expression TEXT,
    expression_confidence REAL,
    smile_probability REAL,
    expression_scores_json TEXT,
    UNIQUE (run_id, face_id)
);

CREATE INDEX IF NOT EXISTS idx_faces_person ON faces(run_id, person_cluster);
CREATE INDEX IF NOT EXISTS idx_faces_person_id ON faces(person_id);
CREATE INDEX IF NOT EXISTS idx_faces_image ON faces(image_id);

CREATE TABLE IF NOT EXISTS albums (
    id INTEGER PRIMARY KEY,
    public_id TEXT NOT NULL UNIQUE,
    title TEXT NOT NULL,
    purpose TEXT NOT NULL DEFAULT 'photobook_demo'
        CHECK (purpose IN ('photobook_demo', 'print')),
    status TEXT NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'ordered', 'archived')),
    target_count INTEGER NOT NULL DEFAULT 24 CHECK (target_count > 0),
    run_id TEXT REFERENCES analysis_runs(id) ON DELETE SET NULL,
    ordered_at TEXT,
    archived_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS album_sources (
    album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    source_root TEXT NOT NULL,
    PRIMARY KEY (album_id, source_root)
);

CREATE TABLE IF NOT EXISTS album_photos (
    album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE RESTRICT,
    position INTEGER NOT NULL,
    added_at TEXT NOT NULL,
    PRIMARY KEY (album_id, image_id)
);

CREATE INDEX IF NOT EXISTS idx_album_photos_order ON album_photos(album_id, position);

CREATE TABLE IF NOT EXISTS album_exports (
    id INTEGER PRIMARY KEY,
    album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    layout_id INTEGER,
    selection_hash TEXT NOT NULL,
    folder TEXT NOT NULL,
    count INTEGER NOT NULL,
    missing_json TEXT NOT NULL DEFAULT '[]',
    exported_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS selection_events (
    id INTEGER PRIMARY KEY,
    album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    run_id TEXT REFERENCES analysis_runs(id) ON DELETE SET NULL,
    image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE RESTRICT,
    action TEXT NOT NULL CHECK (action IN ('add', 'remove', 'seed')),
    source TEXT NOT NULL CHECK (source IN ('auto', 'manual', 'backfill')),
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_selection_events_album ON selection_events(album_id, id);

CREATE TABLE IF NOT EXISTS ranking_models (
    id INTEGER PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('pairwise', 'pointwise')),
    feature_version INTEGER NOT NULL,
    model_json TEXT NOT NULL,
    metrics_json TEXT NOT NULL DEFAULT '{}',
    active INTEGER NOT NULL DEFAULT 0 CHECK (active IN (0, 1)),
    trained_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS image_object_scans (
    image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE CASCADE,
    detector_model TEXT NOT NULL,
    sha256 TEXT NOT NULL,
    objects_json TEXT NOT NULL,
    scanned_at TEXT NOT NULL,
    PRIMARY KEY (image_id, detector_model)
);

CREATE TABLE IF NOT EXISTS layouts (
    id INTEGER PRIMARY KEY,
    album_id INTEGER NOT NULL UNIQUE REFERENCES albums(id) ON DELETE CASCADE,
    run_id TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
    prompt TEXT,
    orientation TEXT NOT NULL,
    spread_count INTEGER NOT NULL,
    min_photos INTEGER NOT NULL,
    max_photos INTEGER NOT NULL,
    selection_hash TEXT NOT NULL,
    assistant_model TEXT,
    unplaced_json TEXT NOT NULL DEFAULT '[]',
    warnings_json TEXT NOT NULL DEFAULT '[]',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS layout_spreads (
    id INTEGER PRIMARY KEY,
    layout_id INTEGER NOT NULL REFERENCES layouts(id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    template_id TEXT NOT NULL,
    story_ids_json TEXT NOT NULL DEFAULT '[]',
    warnings_json TEXT NOT NULL DEFAULT '[]',
    assistant_reason TEXT,
    UNIQUE (layout_id, position)
);

CREATE TABLE IF NOT EXISTS layout_placements (
    spread_id INTEGER NOT NULL REFERENCES layout_spreads(id) ON DELETE CASCADE,
    cell_index INTEGER NOT NULL,
    image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE RESTRICT,
    crop_x REAL NOT NULL,
    crop_y REAL NOT NULL,
    crop_w REAL NOT NULL,
    crop_h REAL NOT NULL,
    fit REAL NOT NULL,
    warnings_json TEXT NOT NULL DEFAULT '[]',
    replaced_image_id INTEGER,
    PRIMARY KEY (spread_id, cell_index)
);

CREATE INDEX IF NOT EXISTS idx_images_availability ON images(availability);
