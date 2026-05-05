# Sistema Autônomo — Microstartup OS

Sistema operacional privado para encontrar oportunidades reais, classificar demanda, gerar entregas com IA, criar propostas comerciais, organizar deals, registrar contatos, controlar abordagem, gerar cobrança Pix/manual e concluir o fluxo até pagamento final.

Versão atual: v1.0.1 — Sequential Automation + Outreach Engine

---

## 1. Visão Geral

O Sistema Autônomo é uma microstartup operacional privada.

Fluxo principal:

Coleta real
→ Quality Gate
→ Pipeline
→ Entrega IA/fallback
→ Proposta comercial
→ Deal
→ Contato
→ Outreach
→ Resposta
→ Cobrança
→ Pagamento
→ Histórico
→ Timeline

Princípio central:

- Executa uma etapa por vez.
- Só avança se a etapa anterior foi concluída.
- Bloqueia em pontos sensíveis.
- Registra tudo em timeline.
- Receita só existe depois de pagamento confirmado.

---

## 2. Estado Atual

Microstartup OS v1.0.1

Status: MVP operacional autônomo controlado
Uso: Privado / Operacional
Ambiente: Termux + Debian proot / Ruby + Sinatra / SQLite / Gemini API

---

## 3. Recursos Atuais

- Dashboard executivo
- Pipeline Kanban Premium
- Coleta real de oportunidades
- Worker automático
- Quality Gate v2
- Gemini para entregas técnicas
- Gemini para propostas comerciais
- Fallback local
- Entregas versionadas
- Export TXT
- Propostas comerciais
- Deals
- Contatos
- Vínculo contato com deal
- Timeline comercial
- Financeiro Pix/manual
- Pagamento confirmado
- Histórico de receita
- Sequential Automation Engine
- Outreach Engine nível 3 base
- Manual Provider
- Response Tracker básico
- Automação até pagamento final
- UI Enterprise Premium
- Clear Architecture Foundation
- Git versionado

---

## 4. Stack

- Ruby
- Sinatra
- SQLite
- ERB
- CSS Enterprise
- Gemini API
- Worker local
- Git
- Termux/Debian

---

## 5. Estrutura Física

sistema-autonomo/
├── app.rb
├── README.md
├── .env.example
├── .gitignore
│
├── app/
│   ├── core/
│   │   ├── bootstrap.rb
│   │   └── database_helpers.rb
│   ├── routes/
│   ├── repositories/
│   │   ├── task_repository.rb
│   │   ├── delivery_repository.rb
│   │   └── deal_repository.rb
│   ├── services/
│   │   ├── ai/
│   │   ├── automation/
│   │   ├── collectors/
│   │   ├── commercial/
│   │   ├── execution/
│   │   ├── filters/
│   │   ├── ingestion/
│   │   ├── outreach/
│   │   └── real_rescan.rb
│   ├── views/
│   └── public/
│       ├── css/
│       ├── js/
│       └── icons/
│
├── config/
│   └── database.rb
├── data/
│   └── sistema_autonomo.sqlite3
├── db/
│   ├── setup.rb
│   ├── add_automation_engine.rb
│   └── add_outreach_engine.rb
├── docs/
│   └── ARCHITECTURE.md
├── scripts/
│   └── architecture_audit.rb
├── storage/
│   ├── exports/
│   ├── logs/
│   └── tmp/
├── tests/
└── workers/
    └── rescan_worker.rb

---

## 6. Módulos e Rotas

### Dashboard Executivo

Rota: /

Mostra receita, deals, conversão, entregas IA, fallback local, histórico e último rescan.

### Pipeline Kanban Premium

Rota: /pipeline

Esteira principal com as etapas Coleta, Filtragem, Execução e Faturamento.

Ações principais:
- Executar IA
- Gerar proposta
- Iniciar fluxo automático
- Copiar task
- Abrir origem real
- Marcar OK/Pago

### Entregas

Rotas:
- /entregas
- /deliveries/:id/export.txt

Gera entregas técnicas com IA ou fallback local, com versionamento e export TXT.

### Comercial

Rotas:
- /comercial
- /deals/:id
- /proposals/:id

Controla propostas, deals, status de negociação e timeline comercial.

Status dos deals:
- proposta_criada
- abordado
- interessado
- fechado
- perdido

### Contatos

Rota: /contacts

Campos principais:
- name
- email
- handle
- platform
- source_url
- notes

### Financeiro

Rota: /financeiro

Controla cobranças Pix/manual, pagamentos pendentes e pagamentos confirmados.

### Histórico / Receitas

Rota: /historico

Guarda tarefas concluídas após pagamento confirmado.

### Automações

Rotas:
- /automations
- /automations/:id
- /tasks/:id/automation/start
- /automations/:id/run-next
- /automations/:id/resume
- /automations/:id/cancel

### Outreach

Rotas:
- /outreach
- /outreach/:id
- /outreach/:id/mark-replied

Gera mensagem, aplica política de segurança, registra envio via manual_provider e controla resposta.

---

## 7. Sequential Automation Engine

Módulo central da v1.0.1.

Responsabilidade:

- Executar uma etapa por vez.
- Validar pré-condições.
- Bloquear quando falta algo.
- Retomar quando a condição for resolvida.
- Concluir somente após pagamento.

Tabelas:
- automation_flows
- automation_steps
- automation_events

Estados principais:
- detected
- qualified
- delivery_generated
- proposal_generated
- contact_ready
- outreach_sent
- interested
- payment_created
- payment_paid
- completed
- blocked
- lost
- cancelled

Fluxo validado:

qualify_task
-> generate_delivery
-> generate_proposal
-> check_contact
-> prepare_outreach
-> wait_interest
-> create_payment
-> wait_payment
-> complete_flow

Regra central:

Nenhuma etapa começa antes da anterior terminar.

---

## 8. Outreach Engine

Módulo de abordagem autônoma controlada.

Responsabilidade:

- Gerar mensagem.
- Aplicar política.
- Bloquear contatos proibidos.
- Evitar duplicidade recente.
- Respeitar limite diário.
- Marcar envio via manual_provider.
- Registrar resposta.
- Avançar fluxo.

Tabelas:
- outreach_messages
- outreach_events
- do_not_contact_entries
- outreach_limits

Status possíveis:
- draft
- policy_approved
- queued
- sent
- replied
- blocked
- cancelled

Provider atual:

manual_provider

Observação:

O manual_provider não envia mensagem real externa. Ele marca a mensagem como enviada de forma controlada. A arquitetura está pronta para trocar por email_provider ou WhatsApp Business no futuro.

---

## 9. Fluxo Completo Validado

Fluxo real testado no sistema:

Task #8
-> Flow #1 iniciado
-> qualify_task done
-> generate_delivery skipped
-> generate_proposal skipped
-> check_contact done
-> prepare_outreach done
-> outreach sent
-> response interested
-> create_payment done
-> payment pending
-> payment paid
-> wait_payment done
-> complete_flow done
-> automation completed

Resultado:
- Flow #1 completed
- Payment #2 paid
- Task #8 ok/historico
- Receita registrada: R$ 720

---

## 10. Instalação

Entrar no projeto:

cd /root/projetos/sistema-autonomo

Instalar dependências:

bundle install

Rodar setup/migrations:

ruby db/setup.rb
ruby db/add_automation_engine.rb
ruby db/add_outreach_engine.rb

Rodar servidor:

ruby app.rb

Acessar:

http://127.0.0.1:4567

---

## 11. Worker

O worker coleta oportunidades automaticamente.

RESCAN_INTERVAL_SECONDS=300 ruby workers/rescan_worker.rb

Logs:

storage/logs/rescan_worker.log

---

## 12. Comandos Úteis

Testar sintaxe:
ruby -c app.rb

Auditoria da arquitetura:
ruby scripts/architecture_audit.rb

Ver tabelas:
sqlite3 data/sistema_autonomo.sqlite3 ".tables"

Ver automações:
sqlite3 data/sistema_autonomo.sqlite3 "select id, task_id, deal_id, current_state, next_action, status from automation_flows order by id desc limit 10;"

Ver outreach:
sqlite3 data/sistema_autonomo.sqlite3 "select id, flow_id, deal_id, provider, status, policy_status, sent_at from outreach_messages order by id desc limit 10;"

Ver pagamentos:
sqlite3 data/sistema_autonomo.sqlite3 "select id, deal_id, task_id, amount, method, status, paid_at from payments order by id desc limit 10;"

---

## 13. Backup

Backup completo do projeto:

mkdir -p /root/backups
BACKUP_NAME="sistema-autonomo-backup-$(date +%Y%m%d-%H%M%S)"
tar -czf "/root/backups/$BACKUP_NAME.tar.gz" -C /root/projetos sistema-autonomo

Dump SQL:

sqlite3 data/sistema_autonomo.sqlite3 ".dump" > "/root/backups/$BACKUP_NAME.sql"

---

## 14. Git

Status:
git status --short

Commit:
git add .
git commit -m "mensagem do commit"

Tags criadas:
- v0.9
- v1.0.1

Histórico atual:
- v0.9: clear architecture, enterprise UI and autonomous commercial pipeline
- v1.0.1: sequential automation and outreach engine

---

## 15. Credenciais e Variáveis de Ambiente

Nunca commite credenciais reais.

Use .env localmente e mantenha .env no .gitignore.

Arquivo seguro de exemplo:
.env.example

Variáveis esperadas:
- APP_ENV
- APP_HOST
- APP_PORT
- GEMINI_API_KEY
- GEMINI_MODEL
- AI_MIN_DELIVERY_CHARS
- AI_MIN_PROPOSAL_CHARS
- RESCAN_INTERVAL_SECONDS
- PIX_PROVIDER
- PIX_WEBHOOK_SECRET
- EMAIL_PROVIDER
- SMTP_HOST
- SMTP_PORT
- SMTP_USER
- SMTP_PASSWORD
- WHATSAPP_PROVIDER
- WHATSAPP_TOKEN
- WHATSAPP_PHONE_NUMBER_ID

---

## 16. Segurança

O projeto deve evitar versionar:
- .env
- .env.*
- data/*.sqlite3
- storage/logs/*
- storage/exports/*
- *.sql
- *.tar.gz

Motivos:
- .env contém segredos
- SQLite contém dados operacionais
- logs podem conter detalhes internos
- exports podem conter entregas comerciais
- dumps podem conter dados sensíveis

---

## 17. .gitignore Recomendado

.bundle/
vendor/bundle/
*.gem

.env
.env.*
!.env.example

data/*.sqlite3
data/*.sqlite3-*
*.db
*.sqlite

*.log
storage/logs/*
!storage/logs/.keep

storage/exports/*
!storage/exports/.keep
storage/tmp/*
!storage/tmp/.keep

*.tar.gz
*.zip
*.sql

.DS_Store
.vscode/
.idea/

node_modules/

---

## 18. Limitações Atuais

- Ainda não possui login/autenticação
- Ainda não possui permissões multiusuário
- Ainda não possui Pix automático real via webhook
- Ainda não possui envio real por email/WhatsApp
- Ainda não possui testes automatizados completos
- app.rb ainda está grande
- rotas ainda precisam ser extraídas para app/routes/
- migrations ainda são scripts manuais

---

## 19. Próximos Passos Técnicos

1. Extrair rotas do app.rb para app/routes/
2. Criar autenticação
3. Criar página de settings
4. Criar .env loader central
5. Criar testes mínimos
6. Criar Pix provider real
7. Criar email_provider
8. Criar WhatsApp Business provider com opt-in
9. Criar backup automático
10. Preparar deploy privado

---

## 20. Roadmap

### v0.9
- Clear Architecture Foundation
- UI Enterprise
- Pipeline Kanban Premium
- Dashboard executivo
- Timeline comercial

### v1.0.1
- Sequential Automation Engine
- Outreach Engine nível 3 base
- Manual Provider
- Response Tracker básico
- Fluxo até pagamento final

### v1.1 sugerida
- Extrair rotas
- Melhorar arquitetura
- Settings
- .env loader
- Backup automático

### v1.2 sugerida
- Payment Provider real
- Pix dinâmico
- Webhook
- Conciliação

### v1.3 sugerida
- Email provider
- Outreach real controlado
- Limites diários
- Do-not-contact

---

## 21. Nível Atual

Projeto: MVP operacional autônomo controlado
Uso privado: alto
Uso como SaaS público: ainda não pronto
Valor técnico: alto para projeto pessoal
Próximo salto: produto privado deployável

---

## 22. Manifesto

Todo micro serviço repetitivo merece um robô.

A escassez é informacional.

Receita só existe depois de pagamento confirmado.

Automação boa sabe quando parar.

Nenhuma etapa começa antes da anterior terminar.
