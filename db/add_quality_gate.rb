require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

columns = db.execute("PRAGMA table_info(tasks)").map { |row| row[1] }

unless columns.include?("quality_status")
  db.execute "ALTER TABLE tasks ADD COLUMN quality_status TEXT DEFAULT 'review';"
end

unless columns.include?("quality_reason")
  db.execute "ALTER TABLE tasks ADD COLUMN quality_reason TEXT DEFAULT 'not_evaluated';"
end

db.execute "CREATE INDEX IF NOT EXISTS idx_tasks_quality_status ON tasks(quality_status);"

puts "Quality Gate aplicado ao banco."
