require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS deliveries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER NOT NULL,
    version INTEGER DEFAULT 1,
    category TEXT,
    content TEXT NOT NULL,
    status TEXT DEFAULT 'draft',
    created_at TEXT,
    updated_at TEXT,
    FOREIGN KEY(task_id) REFERENCES tasks(id)
  );
SQL

db.execute "CREATE INDEX IF NOT EXISTS idx_deliveries_task_id ON deliveries(task_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_deliveries_status ON deliveries(status);"
db.execute "CREATE INDEX IF NOT EXISTS idx_deliveries_created_at ON deliveries(created_at);"

puts "Tabela deliveries criada com sucesso."
