require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS dispatch_autopilot_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    status TEXT DEFAULT 'created',
    total_candidates INTEGER DEFAULT 0,
    sent_count INTEGER DEFAULT 0,
    manual_count INTEGER DEFAULT 0,
    blocked_count INTEGER DEFAULT 0,
    failed_count INTEGER DEFAULT 0,
    summary TEXT,
    created_at TEXT,
    finished_at TEXT
  );
SQL

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS dispatch_autopilot_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id INTEGER,
    outreach_message_id INTEGER,
    dispatch_id INTEGER,
    event_type TEXT,
    status TEXT,
    reason TEXT,
    created_at TEXT
  );
SQL

[
  "ALTER TABLE outreach_messages ADD COLUMN dispatch_autopilot_status TEXT",
  "ALTER TABLE outreach_messages ADD COLUMN dispatch_autopilot_note TEXT",
  "ALTER TABLE outreach_messages ADD COLUMN dispatch_autopilot_at TEXT"
].each do |sql|
  begin
    db.execute sql
  rescue SQLite3::SQLException
  end
end

db.execute "CREATE INDEX IF NOT EXISTS idx_dispatch_autopilot_runs_status ON dispatch_autopilot_runs(status);"
db.execute "CREATE INDEX IF NOT EXISTS idx_dispatch_autopilot_events_run_id ON dispatch_autopilot_events(run_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_dispatch_autopilot_events_message_id ON dispatch_autopilot_events(outreach_message_id);"

puts "Dispatch Autopilot tables OK."
