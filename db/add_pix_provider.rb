require "sqlite3"
require "time"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS pix_webhook_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT,
    txid TEXT,
    reference TEXT,
    provider TEXT DEFAULT 'generic_pix',
    status TEXT,
    amount INTEGER,
    raw_body TEXT,
    signature_valid INTEGER DEFAULT 0,
    processed INTEGER DEFAULT 0,
    processing_error TEXT,
    payment_id INTEGER,
    deal_id INTEGER,
    task_id INTEGER,
    created_at TEXT,
    processed_at TEXT
  );
SQL

db.execute "CREATE INDEX IF NOT EXISTS idx_pix_events_event_id ON pix_webhook_events(event_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_pix_events_txid ON pix_webhook_events(txid);"
db.execute "CREATE INDEX IF NOT EXISTS idx_pix_events_reference ON pix_webhook_events(reference);"
db.execute "CREATE INDEX IF NOT EXISTS idx_pix_events_processed ON pix_webhook_events(processed);"

begin
  db.execute "ALTER TABLE payments ADD COLUMN provider TEXT DEFAULT 'pix_manual';"
rescue SQLite3::SQLException
end

begin
  db.execute "ALTER TABLE payments ADD COLUMN external_reference TEXT;"
rescue SQLite3::SQLException
end

begin
  db.execute "ALTER TABLE payments ADD COLUMN txid TEXT;"
rescue SQLite3::SQLException
end

begin
  db.execute "ALTER TABLE payments ADD COLUMN provider_payload TEXT;"
rescue SQLite3::SQLException
end

puts "Pix Provider tables OK."
