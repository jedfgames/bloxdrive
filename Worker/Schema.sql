CREATE TABLE IF NOT EXISTS packages (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS versions (
    package_id TEXT NOT NULL,
    version INTEGER NOT NULL,
    tree TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now')),
    PRIMARY KEY (package_id, version),
    FOREIGN KEY (package_id) REFERENCES packages(id)
);
