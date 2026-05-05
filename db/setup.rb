require "sqlite3"
require "fileutils"

DB_DIR = File.expand_path("../data", __dir__)
DB_PATH = File.join(DB_DIR, "sistema_autonomo.sqlite3")

FileUtils.mkdir_p(DB_DIR)

db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    external_id TEXT NOT NULL UNIQUE,
    source TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT,
    url TEXT,
    demand_score INTEGER DEFAULT 0,
    suggested_price INTEGER DEFAULT 0,
    status TEXT DEFAULT 'coleta',
    stage TEXT DEFAULT 'coleta',
    result TEXT,
    raw_json TEXT,
    created_at TEXT,
    updated_at TEXT,
    executed_at TEXT,
    paid_at TEXT
  );
SQL

db.execute "CREATE INDEX IF NOT EXISTS idx_tasks_external_id ON tasks(external_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_tasks_stage ON tasks(stage);"
db.execute "CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);"
db.execute "CREATE INDEX IF NOT EXISTS idx_tasks_score ON tasks(demand_score);"
db.execute "CREATE INDEX IF NOT EXISTS idx_tasks_created_at ON tasks(created_at);"

puts "Banco real criado em: #{DB_PATH}"
