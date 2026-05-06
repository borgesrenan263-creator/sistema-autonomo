require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

[
  "ALTER TABLE concierge_decisions ADD COLUMN execution_status TEXT DEFAULT 'pending'",
  "ALTER TABLE concierge_decisions ADD COLUMN execution_result TEXT",
  "ALTER TABLE concierge_decisions ADD COLUMN executed_at TEXT"
].each do |sql|
  begin
    db.execute sql
  rescue SQLite3::SQLException
  end
end

[
  "ALTER TABLE deliveries ADD COLUMN release_status TEXT",
  "ALTER TABLE deliveries ADD COLUMN release_note TEXT",
  "ALTER TABLE deliveries ADD COLUMN released_at TEXT"
].each do |sql|
  begin
    db.execute sql
  rescue SQLite3::SQLException
  end
end

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS concierge_execution_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    decision_id INTEGER,
    entity_type TEXT,
    entity_id INTEGER,
    execution_status TEXT,
    action_taken TEXT,
    result TEXT,
    created_at TEXT
  );
SQL

db.execute "CREATE INDEX IF NOT EXISTS idx_concierge_decisions_execution_status ON concierge_decisions(execution_status);"
db.execute "CREATE INDEX IF NOT EXISTS idx_concierge_execution_events_decision_id ON concierge_execution_events(decision_id);"

puts "Concierge Decision Execution tables OK."
