require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

begin
  db.execute "ALTER TABLE outreach_messages ADD COLUMN reply_body TEXT;"
rescue SQLite3::SQLException
end

puts "outreach_messages.reply_body OK."
