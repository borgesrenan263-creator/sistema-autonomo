require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS ops_heartbeats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    component TEXT NOT NULL,
    status TEXT DEFAULT 'ok',
    detail TEXT,
    metadata TEXT,
    last_seen_at TEXT,
    created_at TEXT,
    updated_at TEXT
  );
SQL

db.execute "CREATE UNIQUE INDEX IF NOT EXISTS idx_ops_heartbeats_component ON ops_heartbeats(component);"
db.execute "CREATE INDEX IF NOT EXISTS idx_ops_heartbeats_last_seen ON ops_heartbeats(last_seen_at);"

puts "Ops Monitoring tables OK."
