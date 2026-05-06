require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)
db = SQLite3::Database.new(DB_PATH)

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS concierge_decisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT,
    entity_id INTEGER,
    decision_type TEXT,
    decision TEXT,
    confidence INTEGER DEFAULT 0,
    risk_level TEXT DEFAULT 'medium',
    reason TEXT,
    action_taken TEXT DEFAULT 'none',
    metadata TEXT,
    created_at TEXT
  );
SQL

db.execute <<~SQL
  CREATE TABLE IF NOT EXISTS concierge_policy_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rule_key TEXT UNIQUE,
    enabled INTEGER DEFAULT 1,
    threshold INTEGER DEFAULT 70,
    action TEXT,
    description TEXT,
    created_at TEXT,
    updated_at TEXT
  );
SQL

db.execute "CREATE INDEX IF NOT EXISTS idx_concierge_decisions_entity ON concierge_decisions(entity_type, entity_id);"
db.execute "CREATE INDEX IF NOT EXISTS idx_concierge_decisions_type ON concierge_decisions(decision_type);"
db.execute "CREATE INDEX IF NOT EXISTS idx_concierge_decisions_decision ON concierge_decisions(decision);"

now = Time.now.utc.iso8601 rescue Time.now.to_s

rules = [
  ["auto_create_charge", 1, 75, "auto_execute", "Criar cobrança quando resposta interessada, deal existe e não há pagamento confirmado."],
  ["block_duplicate_charge", 1, 100, "auto_block", "Bloquear cobrança quando já existe pagamento confirmado."],
  ["auto_send_outreach", 1, 82, "auto_execute", "Permitir envio de abordagem quando oportunidade tem score alto e risco baixo."],
  ["auto_follow_up_payment", 1, 70, "auto_execute", "Permitir follow-up de pagamento pendente dentro da janela segura."],
  ["auto_release_delivery", 1, 85, "auto_execute", "Liberar entrega quando pagamento confirmado e validação/sandbox aprovados."],
  ["block_low_confidence_delivery", 1, 65, "auto_block", "Bloquear entrega automática quando confiança técnica for baixa."]
]

rules.each do |rule_key, enabled, threshold, action, description|
  existing = db.get_first_row("SELECT id FROM concierge_policy_rules WHERE rule_key = ?", [rule_key])

  if existing
    db.execute(
      "UPDATE concierge_policy_rules SET enabled = ?, threshold = ?, action = ?, description = ?, updated_at = ? WHERE rule_key = ?",
      [enabled, threshold, action, description, now, rule_key]
    )
  else
    db.execute(
      "INSERT INTO concierge_policy_rules (rule_key, enabled, threshold, action, description, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      [rule_key, enabled, threshold, action, description, now, now]
    )
  end
end

puts "Concierge Decisions tables OK."
