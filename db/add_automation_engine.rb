require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS automation_flows (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER NOT NULL,
    deal_id INTEGER,
    current_state TEXT DEFAULT 'detected',
    next_action TEXT DEFAULT 'qualify_task',
    status TEXT DEFAULT 'running',
    locked INTEGER DEFAULT 0,
    last_error TEXT,
    started_at TEXT,
    updated_at TEXT,
    completed_at TEXT
  );
SQL

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS automation_steps (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    flow_id INTEGER NOT NULL,
    step_key TEXT NOT NULL,
    status TEXT DEFAULT 'pending',
    started_at TEXT,
    finished_at TEXT,
    error_message TEXT,
    metadata TEXT,
    FOREIGN KEY(flow_id) REFERENCES automation_flows(id)
  );
SQL

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS automation_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    flow_id INTEGER NOT NULL,
    event_type TEXT NOT NULL,
    title TEXT,
    description TEXT,
    metadata TEXT,
    created_at TEXT,
    FOREIGN KEY(flow_id) REFERENCES automation_flows(id)
  );
SQL

db.execute "CREATE INDEX IF NOT EXISTS idx_automation_flows_task_id ON automation_flows(task_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_automation_flows_status ON automation_flows(status);"
db.execute "CREATE INDEX IF NOT EXISTS idx_automation_steps_flow_id ON automation_steps(flow_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_automation_events_flow_id ON automation_events(flow_id);"

puts "Automation Engine tables OK."
