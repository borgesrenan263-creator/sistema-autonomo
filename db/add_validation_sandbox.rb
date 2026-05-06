require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS validation_sandbox_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    delivery_id INTEGER,
    task_id INTEGER,
    validation_run_id INTEGER,
    status TEXT DEFAULT 'pending',
    stack_detected TEXT,
    command TEXT,
    exit_status INTEGER,
    stdout TEXT,
    stderr TEXT,
    evidence_path TEXT,
    workspace_path TEXT,
    started_at TEXT,
    finished_at TEXT,
    error TEXT
  );
SQL

db.execute "CREATE INDEX IF NOT EXISTS idx_validation_sandbox_delivery_id ON validation_sandbox_runs(delivery_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_validation_sandbox_status ON validation_sandbox_runs(status);"

begin
  db.execute "ALTER TABLE validation_runs ADD COLUMN sandbox_status TEXT;"
rescue SQLite3::SQLException
end

begin
  db.execute "ALTER TABLE validation_runs ADD COLUMN sandbox_evidence_path TEXT;"
rescue SQLite3::SQLException
end

puts "Validation Sandbox tables OK."
