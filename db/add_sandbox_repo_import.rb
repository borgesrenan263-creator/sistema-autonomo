require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

[
  "ALTER TABLE validation_sandbox_runs ADD COLUMN repo_url TEXT",
  "ALTER TABLE validation_sandbox_runs ADD COLUMN repo_import_status TEXT",
  "ALTER TABLE validation_sandbox_runs ADD COLUMN repo_import_error TEXT",
  "ALTER TABLE validation_sandbox_runs ADD COLUMN workspace_size_kb INTEGER DEFAULT 0"
].each do |sql|
  begin
    db.execute sql
  rescue SQLite3::SQLException
  end
end

puts "Sandbox repo import columns OK."
