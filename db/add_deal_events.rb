require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS deal_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    deal_id INTEGER NOT NULL,
    event_type TEXT NOT NULL,
    title TEXT,
    description TEXT,
    metadata TEXT,
    created_at TEXT,
    FOREIGN KEY(deal_id) REFERENCES deals(id)
  );
SQL

db.execute "CREATE INDEX IF NOT EXISTS idx_deal_events_deal_id ON deal_events(deal_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_deal_events_event_type ON deal_events(event_type);"
db.execute "CREATE INDEX IF NOT EXISTS idx_deal_events_created_at ON deal_events(created_at);"

puts "Tabela deal_events criada com sucesso."
