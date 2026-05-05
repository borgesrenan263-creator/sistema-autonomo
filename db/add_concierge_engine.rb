require "sqlite3"
require "time"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS concierge_requests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    flow_id INTEGER,
    task_id INTEGER,
    deal_id INTEGER,
    request_type TEXT NOT NULL,
    status TEXT DEFAULT 'pending',
    title TEXT,
    description TEXT,
    action_label TEXT,
    result_message TEXT,
    created_at TEXT,
    updated_at TEXT,
    resolved_at TEXT
  );
SQL

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS concierge_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id INTEGER,
    flow_id INTEGER,
    event_type TEXT,
    title TEXT,
    description TEXT,
    created_at TEXT
  );
SQL

db.execute "CREATE INDEX IF NOT EXISTS idx_concierge_requests_flow_id ON concierge_requests(flow_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_concierge_requests_status ON concierge_requests(status);"
db.execute "CREATE INDEX IF NOT EXISTS idx_concierge_events_flow_id ON concierge_events(flow_id);"

puts "Concierge Engine tables OK."
