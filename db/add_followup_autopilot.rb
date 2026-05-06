require "sqlite3"
require "time"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS followup_tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT,
    entity_id INTEGER,
    followup_type TEXT,
    status TEXT DEFAULT 'pending',
    priority INTEGER DEFAULT 50,
    due_at TEXT,
    attempts INTEGER DEFAULT 0,
    max_attempts INTEGER DEFAULT 3,
    message TEXT,
    last_error TEXT,
    created_at TEXT,
    updated_at TEXT
  );
SQL

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS followup_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    followup_task_id INTEGER,
    entity_type TEXT,
    entity_id INTEGER,
    event_type TEXT,
    title TEXT,
    detail TEXT,
    created_at TEXT
  );
SQL

[
  "ALTER TABLE deals ADD COLUMN followup_status TEXT",
  "ALTER TABLE deals ADD COLUMN last_followup_at TEXT",
  "ALTER TABLE payments ADD COLUMN followup_status TEXT",
  "ALTER TABLE payments ADD COLUMN last_followup_at TEXT"
].each do |sql|
  begin
    db.execute sql
  rescue SQLite3::SQLException
  end
end

db.execute "CREATE INDEX IF NOT EXISTS idx_followup_tasks_entity ON followup_tasks(entity_type, entity_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_followup_tasks_status ON followup_tasks(status);"
db.execute "CREATE INDEX IF NOT EXISTS idx_followup_tasks_due_at ON followup_tasks(due_at);"
db.execute "CREATE INDEX IF NOT EXISTS idx_followup_events_task_id ON followup_events(followup_task_id);"

puts "Follow-up Autopilot tables OK."
