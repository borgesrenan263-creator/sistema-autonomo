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
