require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS outreach_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    flow_id INTEGER,
    deal_id INTEGER,
    task_id INTEGER,
    contact_id INTEGER,
    channel TEXT DEFAULT 'manual_provider',
    provider TEXT DEFAULT 'manual_provider',
    status TEXT DEFAULT 'draft',
    risk_level TEXT DEFAULT 'low',
    policy_status TEXT DEFAULT 'pending',
    policy_reason TEXT,
    subject TEXT,
    message_body TEXT,
    sent_at TEXT,
    replied_at TEXT,
    response_status TEXT,
    created_at TEXT,
    updated_at TEXT
  );
SQL

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS outreach_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    outreach_message_id INTEGER,
    flow_id INTEGER,
    deal_id INTEGER,
    event_type TEXT,
    title TEXT,
    description TEXT,
    metadata TEXT,
    created_at TEXT
  );
SQL

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS do_not_contact_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    contact_id INTEGER,
    value TEXT,
    reason TEXT,
    created_at TEXT
  );
SQL

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS outreach_limits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    limit_key TEXT UNIQUE,
    limit_value INTEGER,
    created_at TEXT,
    updated_at TEXT
  );
SQL

now = Time.now.utc.iso8601 rescue Time.now.to_s

db.execute(
  "INSERT OR IGNORE INTO outreach_limits (limit_key, limit_value, created_at, updated_at) VALUES (?, ?, ?, ?)",
  ["daily_manual_provider", 20, now, now]
)

db.execute "CREATE INDEX IF NOT EXISTS idx_outreach_messages_flow_id ON outreach_messages(flow_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_outreach_messages_deal_id ON outreach_messages(deal_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_outreach_messages_contact_id ON outreach_messages(contact_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_outreach_messages_status ON outreach_messages(status);"
db.execute "CREATE INDEX IF NOT EXISTS idx_do_not_contact_contact_id ON do_not_contact_entries(contact_id);"

puts "Outreach Engine tables OK."
