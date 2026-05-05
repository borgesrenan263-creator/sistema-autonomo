require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

columns = db.execute("PRAGMA table_info(proposals)").map { |row| row[1] }

unless columns.include?("generator_type")
  db.execute "ALTER TABLE proposals ADD COLUMN generator_type TEXT DEFAULT 'fallback';"
end

unless columns.include?("provider")
  db.execute "ALTER TABLE proposals ADD COLUMN provider TEXT DEFAULT 'local';"
end

unless columns.include?("model")
  db.execute "ALTER TABLE proposals ADD COLUMN model TEXT DEFAULT 'proposal_builder';"
end

unless columns.include?("error_message")
  db.execute "ALTER TABLE proposals ADD COLUMN error_message TEXT;"
end

puts "Campos IA adicionados em proposals."
