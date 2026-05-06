# frozen_string_literal: true

require "sqlite3"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
DB_PATH = File.join(ROOT, "data", "sistema_autonomo.sqlite3")

FileUtils.mkdir_p(File.dirname(DB_PATH))

db = SQLite3::Database.new(DB_PATH)
db.results_as_hash = true

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS autopilot_daily_loop_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    trigger_source TEXT,
    status TEXT NOT NULL DEFAULT 'running',
    started_at TEXT,
    finished_at TEXT,
    duration_seconds INTEGER DEFAULT 0,

    steps_total INTEGER DEFAULT 0,
    steps_ok INTEGER DEFAULT 0,
    steps_failed INTEGER DEFAULT 0,

    followups_before INTEGER DEFAULT 0,
    followups_after INTEGER DEFAULT 0,
    followups_created INTEGER DEFAULT 0,
    followups_processed INTEGER DEFAULT 0,

    decisions_pending_before INTEGER DEFAULT 0,
    decisions_pending_after INTEGER DEFAULT 0,
    decisions_executed INTEGER DEFAULT 0,

    dispatch_runs_before INTEGER DEFAULT 0,
    dispatch_runs_after INTEGER DEFAULT 0,
    dispatch_sent INTEGER DEFAULT 0,
    dispatch_manual INTEGER DEFAULT 0,
    dispatch_blocked INTEGER DEFAULT 0,

    revenue_before REAL DEFAULT 0,
    revenue_after REAL DEFAULT 0,
    pending_before REAL DEFAULT 0,
    pending_after REAL DEFAULT 0,

    summary TEXT,
    error TEXT,
    created_at TEXT,
    updated_at TEXT
  );
SQL

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS autopilot_daily_loop_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id INTEGER,
    step_key TEXT,
    step_title TEXT,
    status TEXT,
    detail TEXT,
    error TEXT,
    started_at TEXT,
    finished_at TEXT,
    duration_seconds INTEGER DEFAULT 0,
    created_at TEXT,
    FOREIGN KEY(run_id) REFERENCES autopilot_daily_loop_runs(id)
  );
SQL

puts "Migration add_autopilot_daily_loop concluída."
