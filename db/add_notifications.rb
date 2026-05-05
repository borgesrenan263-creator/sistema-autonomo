require "sqlite3"
require "time"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS system_notifications (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    body TEXT,
    status TEXT DEFAULT 'unread',
    link TEXT,
    metadata TEXT,
    created_at TEXT,
    read_at TEXT
  );
SQL

db.execute "CREATE INDEX IF NOT EXISTS idx_system_notifications_status ON system_notifications(status);"
db.execute "CREATE INDEX IF NOT EXISTS idx_system_notifications_kind ON system_notifications(kind);"

puts "Notifications tables OK."
