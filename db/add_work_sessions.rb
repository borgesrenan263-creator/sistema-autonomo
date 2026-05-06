require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS work_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    status TEXT DEFAULT 'active',
    started_at TEXT,
    ended_at TEXT,
    title TEXT,
    notes TEXT,
    revenue_start REAL DEFAULT 0,
    revenue_end REAL DEFAULT 0,
    revenue_delta REAL DEFAULT 0,
    actions_count INTEGER DEFAULT 0,
    created_at TEXT,
    updated_at TEXT
  );
SQL

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS work_session_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    work_session_id INTEGER,
    event_type TEXT,
    title TEXT,
    body TEXT,
    link TEXT,
    metadata TEXT,
    created_at TEXT
  );
SQL

db.execute "CREATE INDEX IF NOT EXISTS idx_work_sessions_status ON work_sessions(status);"
db.execute "CREATE INDEX IF NOT EXISTS idx_work_session_events_session_id ON work_session_events(work_session_id);"

puts "Work Sessions tables OK."
