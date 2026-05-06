require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS response_actions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    response_event_id INTEGER,
    deal_id INTEGER,
    task_id INTEGER,
    contact_id INTEGER,
    action_type TEXT,
    status TEXT DEFAULT 'done',
    note TEXT,
    created_at TEXT
  );
SQL

[
  "ALTER TABLE response_inbox_events ADD COLUMN action_status TEXT",
  "ALTER TABLE response_inbox_events ADD COLUMN action_note TEXT",
  "ALTER TABLE response_inbox_events ADD COLUMN actioned_at TEXT"
].each do |sql|
  begin
    db.execute sql
  rescue SQLite3::SQLException
  end
end

db.execute "CREATE INDEX IF NOT EXISTS idx_response_actions_event_id ON response_actions(response_event_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_response_actions_deal_id ON response_actions(deal_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_response_inbox_action_status ON response_inbox_events(action_status);"

puts "Response Actions tables OK."
