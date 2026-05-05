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
