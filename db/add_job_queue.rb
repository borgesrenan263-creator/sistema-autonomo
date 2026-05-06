require "sqlite3"
require "time"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_type TEXT NOT NULL,
    status TEXT DEFAULT 'queued',
    priority INTEGER DEFAULT 50,
    attempts INTEGER DEFAULT 0,
    max_attempts INTEGER DEFAULT 3,
    payload TEXT,
    result TEXT,
    last_error TEXT,
    locked_at TEXT,
    run_at TEXT,
    started_at TEXT,
    finished_at TEXT,
    created_at TEXT,
    updated_at TEXT
  );
SQL

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS job_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id INTEGER,
    event_type TEXT,
    title TEXT,
    detail TEXT,
    created_at TEXT
  );
SQL

db.execute "CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status);"
db.execute "CREATE INDEX IF NOT EXISTS idx_jobs_type ON jobs(job_type);"
db.execute "CREATE INDEX IF NOT EXISTS idx_jobs_priority ON jobs(priority);"
db.execute "CREATE INDEX IF NOT EXISTS idx_jobs_run_at ON jobs(run_at);"
db.execute "CREATE INDEX IF NOT EXISTS idx_job_events_job_id ON job_events(job_id);"

puts "Job Queue tables OK."
