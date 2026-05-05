require "sqlite3"
require "time"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS channel_dispatches (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    outreach_message_id INTEGER,
    flow_id INTEGER,
    deal_id INTEGER,
    contact_id INTEGER,
    channel TEXT DEFAULT 'email',
    provider TEXT DEFAULT 'manual_channel',
    recipient TEXT,
    subject TEXT,
    body TEXT,
    status TEXT DEFAULT 'queued',
    policy_status TEXT DEFAULT 'pending',
    policy_reason TEXT,
    attempts INTEGER DEFAULT 0,
    last_error TEXT,
    created_at TEXT,
    updated_at TEXT,
    sent_at TEXT
  );
SQL

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS observability_signals (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    signal_type TEXT NOT NULL,
    entity_type TEXT,
    entity_id INTEGER,
    flow_id INTEGER,
    deal_id INTEGER,
    task_id INTEGER,
    severity TEXT DEFAULT 'info',
    status TEXT DEFAULT 'open',
    title TEXT,
    detail TEXT,
    link TEXT,
    metadata TEXT,
    created_at TEXT,
    resolved_at TEXT
  );
SQL

db.execute "CREATE INDEX IF NOT EXISTS idx_channel_dispatches_status ON channel_dispatches(status);"
db.execute "CREATE INDEX IF NOT EXISTS idx_channel_dispatches_flow_id ON channel_dispatches(flow_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_channel_dispatches_outreach ON channel_dispatches(outreach_message_id);"

db.execute "CREATE INDEX IF NOT EXISTS idx_observability_signals_status ON observability_signals(status);"
db.execute "CREATE INDEX IF NOT EXISTS idx_observability_signals_type ON observability_signals(signal_type);"
db.execute "CREATE INDEX IF NOT EXISTS idx_observability_signals_flow ON observability_signals(flow_id);"

puts "Channel Dispatch + Observability tables OK."
