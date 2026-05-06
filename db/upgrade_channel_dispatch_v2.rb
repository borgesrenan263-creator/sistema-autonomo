require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

[
  "ALTER TABLE channel_dispatches ADD COLUMN external_message_id TEXT",
  "ALTER TABLE channel_dispatches ADD COLUMN locked_at TEXT",
  "ALTER TABLE channel_dispatches ADD COLUMN completed_at TEXT",
  "ALTER TABLE channel_dispatches ADD COLUMN send_window_status TEXT",
  "ALTER TABLE channel_dispatches ADD COLUMN delivery_log TEXT"
].each do |sql|
  begin
    db.execute sql
  rescue SQLite3::SQLException
  end
end

db.execute "CREATE INDEX IF NOT EXISTS idx_channel_dispatches_provider ON channel_dispatches(provider);"
db.execute "CREATE INDEX IF NOT EXISTS idx_channel_dispatches_sent_at ON channel_dispatches(sent_at);"

puts "Channel Dispatch v2 columns OK."
