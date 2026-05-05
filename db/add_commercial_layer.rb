require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS contacts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT,
    email TEXT,
    handle TEXT,
    platform TEXT,
    source_url TEXT,
    notes TEXT,
    created_at TEXT,
    updated_at TEXT
  );
SQL

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS proposals (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER NOT NULL,
    delivery_id INTEGER,
    title TEXT NOT NULL,
    pain_summary TEXT,
    solution_scope TEXT,
    out_of_scope TEXT,
    price INTEGER DEFAULT 0,
    estimated_timeline TEXT,
    approach_message TEXT,
    status TEXT DEFAULT 'draft',
    created_at TEXT,
    updated_at TEXT,
    FOREIGN KEY(task_id) REFERENCES tasks(id),
    FOREIGN KEY(delivery_id) REFERENCES deliveries(id)
  );
SQL

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS deals (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER NOT NULL,
    proposal_id INTEGER,
    contact_id INTEGER,
    status TEXT DEFAULT 'novo',
    value INTEGER DEFAULT 0,
    next_action TEXT,
    notes TEXT,
    created_at TEXT,
    updated_at TEXT,
    closed_at TEXT,
    FOREIGN KEY(task_id) REFERENCES tasks(id),
    FOREIGN KEY(proposal_id) REFERENCES proposals(id),
    FOREIGN KEY(contact_id) REFERENCES contacts(id)
  );
SQL

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS payments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    deal_id INTEGER,
    task_id INTEGER,
    amount INTEGER DEFAULT 0,
    method TEXT DEFAULT 'pix_manual',
    pix_label TEXT DEFAULT 'PIX configurado',
    status TEXT DEFAULT 'pending',
    reference TEXT,
    paid_at TEXT,
    created_at TEXT,
    updated_at TEXT,
    FOREIGN KEY(deal_id) REFERENCES deals(id),
    FOREIGN KEY(task_id) REFERENCES tasks(id)
  );
SQL

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS acceptances (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    deal_id INTEGER,
    delivery_id INTEGER,
    accepted_by TEXT,
    acceptance_text TEXT,
    status TEXT DEFAULT 'pending',
    accepted_at TEXT,
    created_at TEXT,
    updated_at TEXT,
    FOREIGN KEY(deal_id) REFERENCES deals(id),
    FOREIGN KEY(delivery_id) REFERENCES deliveries(id)
  );
SQL

db.execute "CREATE INDEX IF NOT EXISTS idx_contacts_platform ON contacts(platform);"
db.execute "CREATE INDEX IF NOT EXISTS idx_proposals_task_id ON proposals(task_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_proposals_status ON proposals(status);"
db.execute "CREATE INDEX IF NOT EXISTS idx_deals_status ON deals(status);"
db.execute "CREATE INDEX IF NOT EXISTS idx_deals_task_id ON deals(task_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_payments_status ON payments(status);"
db.execute "CREATE INDEX IF NOT EXISTS idx_acceptances_status ON acceptances(status);"

puts "Camada comercial criada com sucesso."
