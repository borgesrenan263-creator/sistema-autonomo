#!/usr/bin/env bash
set -e

echo "== Sistema Autônomo — Setup Clear Architecture SAFE =="

mkdir -p app/routes app/repositories app/models app/policies app/presenters app/lib app/core config docs tests storage/tmp storage/exports storage/logs scripts

cat > config/database.rb <<'RUBY'
require "sqlite3"
require "fileutils"

module DatabaseConfig
  ROOT_DIR = File.expand_path("..", __dir__)
  DATA_DIR = File.join(ROOT_DIR, "data")
  DB_PATH = File.join(DATA_DIR, "sistema_autonomo.sqlite3")

  def self.ensure_data_dir!
    FileUtils.mkdir_p(DATA_DIR)
  end

  def self.connect
    ensure_data_dir!

    db = SQLite3::Database.new(DB_PATH)
    db.results_as_hash = true
    db
  end
end
RUBY

cat > docs/ARCHITECTURE.md <<'MARKDOWN'
# Sistema Autonomo — Clear Architecture

## Objetivo

O Sistema Autonomo e um motor privado para:

1. Coletar oportunidades reais
2. Classificar com Quality Gate
3. Gerar entregas com IA/fallback
4. Gerar propostas comerciais
5. Criar deals
6. Organizar contatos
7. Cobrar via Pix/manual
8. Registrar pagamento
9. Manter historico e timeline

---

## Estrutura fisica

Entrada
- app.rb
- app/routes/

Core
- app/core/
- config/

Dominio
- app/models/
- app/policies/

Dados
- app/repositories/
- data/sistema_autonomo.sqlite3

Servicos
- app/services/
- app/services/ai/
- app/services/collectors/
- app/services/commercial/
- app/services/execution/
- app/services/filters/
- app/services/ingestion/

Interface
- app/views/
- app/public/css/
- app/public/js/
- app/public/icons/

Automacao
- workers/

Operacao
- scripts/
- storage/logs/
- storage/exports/
- storage/tmp/

Documentacao
- docs/

---

## Fluxo principal

Worker / FORCE_RESCAN
-> Collectors
-> TaskIngestor
-> QualityGate
-> tasks
-> Pipeline
-> DeliveryGenerator
-> deliveries
-> CommercialProposalGenerator
-> proposals
-> deals
-> payments
-> historico

---

## Regras da arquitetura

### app.rb

Deve ficar cada vez menor.

Responsabilidade ideal:
- carregar dependencias
- configurar Sinatra
- carregar rotas
- iniciar app

### app/routes

Responsavel por HTTP.

Exemplos:
- GET /pipeline
- POST /tasks/:id/execute
- GET /comercial
- POST /deals/:id/status

### app/services

Responsavel por logica operacional.

Exemplos:
- RealRescan
- DeliveryGenerator
- CommercialProposalGenerator
- QualityGate
- TaskIngestor
- DealEventLogger

### app/repositories

Responsavel por acesso ao banco.

Exemplos:
- TaskRepository
- DeliveryRepository
- DealRepository
- PaymentRepository
- ContactRepository

### app/views

Responsavel por HTML/ERB.

### workers

Responsavel por processos automaticos.

### scripts

Responsavel por manutencao, auditoria, backup e ferramentas.

---

## Estado atual do sistema

O sistema ja possui:
- Dashboard executivo
- Pipeline Kanban Premium
- Entregas versionadas
- Gemini com retry
- Fallback local
- Propostas comerciais com Gemini/fallback
- Deals
- Contatos
- Financeiro Pix/manual
- Historico de receita
- Timeline comercial
- Worker automatico
- Sistema / Logs
- Quality Gate v2
- Export TXT

---

## Proximos passos da Clear Architecture

1. Mover rotas para app/routes/
2. Reduzir app.rb
3. Centralizar acesso ao banco em repositories
4. Criar presenters para telas complexas
5. Criar policies para regras comerciais
6. Criar testes minimos
7. Criar .env.example
8. Preparar deploy privado

---

## Estado tecnico atual

Microstartup OS v0.9 — Clear Architecture Foundation

Base criada:
- config/database.rb
- app/core/bootstrap.rb
- app/core/database_helpers.rb
- app/repositories/
- app/services/commercial/deal_event_logger.rb
- docs/ARCHITECTURE.md
- scripts/architecture_audit.rb
- README.md

Ainda pendente:
- extrair rotas do app.rb
- reduzir app.rb
- padronizar migrations
- criar testes basicos
MARKDOWN

cat > app/core/database_helpers.rb <<'RUBY'
module DatabaseHelpers
  def db_all(sql, params = [])
    DB.execute(sql, params).map do |row|
      row.reject { |k, _| k.is_a?(Integer) }
    end
  end

  def db_one(sql, params = [])
    row = DB.get_first_row(sql, params)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
RUBY

cat > app/core/bootstrap.rb <<'RUBY'
require "sinatra"
require "json"
require "time"
require "fileutils"
require "csv"

require_relative "../../config/database"
require_relative "database_helpers"

require_relative "../services/real_rescan"
require_relative "../services/execution/local_delivery_builder"
require_relative "../services/ai/delivery_generator"
require_relative "../services/commercial/proposal_builder"
require_relative "../services/commercial/commercial_proposal_generator"
require_relative "../services/commercial/deal_event_logger"

require_relative "../repositories/task_repository"
require_relative "../repositories/delivery_repository"
require_relative "../repositories/deal_repository"
RUBY

cat > app/services/commercial/deal_event_logger.rb <<'RUBY'
require "time"

class DealEventLogger
  def initialize(db)
    @db = db
  end

  def create(deal_id:, event_type:, title:, description: nil, metadata: nil)
    @db.execute(
      <<~SQL,
        INSERT INTO deal_events
        (
          deal_id,
          event_type,
          title,
          description,
          metadata,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?)
      SQL
      [
        deal_id,
        event_type,
        title,
        description,
        metadata,
        Time.now.iso8601
      ]
    )
  end
end
RUBY

cat > app/repositories/task_repository.rb <<'RUBY'
class TaskRepository
  def initialize(db)
    @db = db
  end

  def find(id)
    clean(@db.get_first_row("SELECT * FROM tasks WHERE id = ?", [id]))
  end

  def latest(limit: 250)
    @db.execute(
      <<~SQL,
        SELECT *
        FROM tasks
        WHERE quality_status != 'ignore'
        ORDER BY
          CASE quality_status
            WHEN 'monetizable' THEN 3
            WHEN 'review' THEN 2
            ELSE 1
          END DESC,
          demand_score DESC,
          suggested_price DESC,
          id DESC
        LIMIT ?
      SQL
      [limit]
    ).map { |row| clean(row) }
  end

  def mark_ok(id, paid_at:)
    @db.execute(
      <<~SQL,
        UPDATE tasks
        SET status = 'ok',
            stage = 'historico',
            paid_at = ?,
            updated_at = ?
        WHERE id = ?
      SQL
      [paid_at, paid_at, id]
    )
  end

  private

  def clean(row)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
RUBY

cat > app/repositories/delivery_repository.rb <<'RUBY'
class DeliveryRepository
  def initialize(db)
    @db = db
  end

  def latest_for_task(task_id)
    clean(
      @db.get_first_row(
        "SELECT * FROM deliveries WHERE task_id = ? ORDER BY version DESC LIMIT 1",
        [task_id]
      )
    )
  end

  def next_version(task_id)
    row = @db.get_first_row(
      "SELECT COALESCE(MAX(version), 0) AS version FROM deliveries WHERE task_id = ?",
      [task_id]
    )

    row["version"].to_i + 1
  end

  private

  def clean(row)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
RUBY

cat > app/repositories/deal_repository.rb <<'RUBY'
class DealRepository
  OPEN_STATUSES = ["proposta_criada", "abordado", "interessado"]

  def initialize(db)
    @db = db
  end

  def find(id)
    clean(@db.get_first_row("SELECT * FROM deals WHERE id = ?", [id]))
  end

  def open_for_task(task_id)
    clean(
      @db.get_first_row(
        <<~SQL,
          SELECT deals.*, proposals.id AS proposal_id
          FROM deals
          LEFT JOIN proposals ON proposals.id = deals.proposal_id
          WHERE deals.task_id = ?
            AND deals.status IN ('proposta_criada', 'abordado', 'interessado')
          ORDER BY deals.id DESC
          LIMIT 1
        SQL
        [task_id]
      )
    )
  end

  private

  def clean(row)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
RUBY

cat > scripts/architecture_audit.rb <<'RUBY'
root = File.expand_path("..", __dir__)

paths = {
  "app.rb" => File.join(root, "app.rb"),
  "config/database.rb" => File.join(root, "config/database.rb"),
  "app/core/bootstrap.rb" => File.join(root, "app/core/bootstrap.rb"),
  "app/core/database_helpers.rb" => File.join(root, "app/core/database_helpers.rb"),
  "app/routes" => File.join(root, "app/routes"),
  "app/repositories" => File.join(root, "app/repositories"),
  "app/services" => File.join(root, "app/services"),
  "app/views" => File.join(root, "app/views"),
  "workers" => File.join(root, "workers"),
  "docs/ARCHITECTURE.md" => File.join(root, "docs/ARCHITECTURE.md")
}

puts "SISTEMA AUTONOMO — ARCHITECTURE AUDIT"
puts "===================================="

paths.each do |label, path|
  status = File.exist?(path) || Dir.exist?(path) ? "OK" : "MISSING"
  puts "#{status.ljust(8)} #{label}"
end

app_rb = File.join(root, "app.rb")

if File.exist?(app_rb)
  lines = File.readlines(app_rb).count
  puts
  puts "app.rb lines: #{lines}"

  if lines > 700
    puts "WARN: app.rb ainda esta grande. Proximo passo: mover rotas para app/routes."
  else
    puts "OK: app.rb em tamanho aceitavel."
  end
end
RUBY

cat > README.md <<'MARKDOWN'
# Sistema Autonomo

Microstartup OS privado para encontrar oportunidades reais, gerar entregas com IA, criar propostas comerciais, organizar deals, cobrar via Pix/manual e registrar receita.

## Stack

- Ruby
- Sinatra
- SQLite
- ERB
- Gemini API
- Worker local
- Termux/Debian

## Modulos

- Dashboard
- Pipeline
- Entregas
- Comercial
- Contatos
- Financeiro
- Historico
- Sistema / Logs
- Manifesto

## Fluxo

Coleta real
-> Quality Gate
-> Entrega IA/fallback
-> Proposta IA/fallback
-> Deal
-> Contato
-> Cobranca
-> Pagamento
-> Receita
-> Timeline

## Rodar

bundle install
ruby app.rb

Acessar:

http://127.0.0.1:4567

## Worker

RESCAN_INTERVAL_SECONDS=300 ruby workers/rescan_worker.rb

## Backup

tar -czf /root/backups/sistema-autonomo.tar.gz -C /root/projetos sistema-autonomo
sqlite3 data/sistema_autonomo.sqlite3 ".dump" > /root/backups/sistema-autonomo.sql

## Arquitetura

Ver:

cat docs/ARCHITECTURE.md
MARKDOWN

echo
echo "== Auditoria da arquitetura =="
ruby scripts/architecture_audit.rb

echo
echo "== Teste de sintaxe do app.rb =="
ruby -c app.rb

echo
echo "== Preview da documentacao =="
head -n 60 docs/ARCHITECTURE.md

echo
echo "Clear Architecture Foundation criada/atualizada com sucesso."
