require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS validation_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    delivery_id INTEGER,
    task_id INTEGER,
    status TEXT DEFAULT 'pending',
    score INTEGER DEFAULT 0,
    stack_detected TEXT,
    summary TEXT,
    evidence_path TEXT,
    findings TEXT,
    created_at TEXT,
    completed_at TEXT,
    error TEXT
  );
SQL

db.execute "CREATE INDEX IF NOT EXISTS idx_validation_runs_delivery_id ON validation_runs(delivery_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_validation_runs_status ON validation_runs(status);"

begin
  db.execute "ALTER TABLE deliveries ADD COLUMN validation_status TEXT;"
rescue SQLite3::SQLException
end

begin
  db.execute "ALTER TABLE deliveries ADD COLUMN validation_score INTEGER DEFAULT 0;"
rescue SQLite3::SQLException
end

begin
  db.execute "ALTER TABLE deliveries ADD COLUMN validated_at TEXT;"
rescue SQLite3::SQLException
end

puts "Validation Engine tables OK."
