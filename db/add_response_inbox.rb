require "sqlite3"
require "time"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS response_inbox_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT,
    provider TEXT DEFAULT 'generic_response',
    channel TEXT DEFAULT 'webhook',
    sender TEXT,
    recipient TEXT,
    subject TEXT,
    body TEXT,
    response_status TEXT,
    raw_body TEXT,
    signature_valid INTEGER DEFAULT 0,
    processed INTEGER DEFAULT 0,
    processing_error TEXT,
    outreach_message_id INTEGER,
    flow_id INTEGER,
    deal_id INTEGER,
    contact_id INTEGER,
    task_id INTEGER,
    created_at TEXT,
    processed_at TEXT
  );
SQL

db.execute "CREATE INDEX IF NOT EXISTS idx_response_inbox_event_id ON response_inbox_events(event_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_response_inbox_processed ON response_inbox_events(processed);"
db.execute "CREATE INDEX IF NOT EXISTS idx_response_inbox_flow ON response_inbox_events(flow_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_response_inbox_deal ON response_inbox_events(deal_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_response_inbox_contact ON response_inbox_events(contact_id);"

puts "Response Inbox tables OK."
