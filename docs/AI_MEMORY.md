# SISTEMA AUTÔNOMO — AI MEMORY

Última atualização manual: 2026-05-06
Versão atual: v3.5.2
Branch atual: v1.1-extract-routes

---

## 1. Identidade do projeto

Sistema Autônomo é uma microstartup OS solo para trabalho remoto e geração de renda operacional semi/autônoma.

Objetivo central:

> Construir uma esteira 95% automática, onde o sistema detecta oportunidades, prepara propostas, acompanha respostas, cobra, entrega, faz follow-up e só escala exceções quando necessário.

Não é SaaS público agora.
É uma ferramenta pessoal/solo.

---

## 2. Stack atual

- Ruby 3.3+
- Sinatra
- SQLite local
- Puma
- HTML/ERB
- Worker Ruby
- SMTP Gmail com senha de app
- Pix/manual/webhook
- Git tags por versão

Banco principal:

data/sistema_autonomo.sqlite3

Servidor local:

http://127.0.0.1:4567

---

## 3. Regras operacionais do usuário

- Sempre separar reinício de servidor dos testes.
- Sempre usar comandos claros para Termux/proot.
- Preferência por `cat > arquivo <<'EOF'`.
- Sempre versionar com git commit + tag.
- Não misturar muitas mudanças sem teste.
- Segurança antes de envio automático externo.
- Sistema é solo, não multiusuário enterprise por enquanto.
- Objetivo maior: autonomia de renda, mas sem spam e sem duplicidade.

---

## 4. Estado atual por versão

### v3.0 — Solo Daily Operator Command Center

Criado centro operacional diário.

Funções:
- resumo do sistema
- próximo passo
- money snapshot
- oportunidades
- deliveries
- jobs
- monitoring
- checklist operacional

Endpoints:
- GET /command-center
- GET /command-center.json
- POST /command-center/run-cycle

---

### v3.1 — Inbox Action Center

Criado centro de ação para respostas recebidas.

Funções:
- listar respostas interessadas
- sugerir mensagem
- marcar interessado
- criar cobrança
- registrar ações

Endpoints:
- GET /responses/action-center
- GET /responses/action-center.json
- GET /responses/:id/suggested-message
- POST /responses/:id/mark-interested
- POST /responses/:id/create-charge

---

### v3.1.1 — Duplicate charge protection

Correção:
- evita criar cobrança se deal já possui payment paid.

Resultado validado:
- response #3 virou already_paid quando deal #3 já tinha pagamento confirmado.

---

### v3.2 — Daily Work Session Runbook

Criado módulo de sessão de trabalho.

Funções:
- iniciar sessão
- registrar ações
- rodar ciclo diário
- encerrar sessão
- medir revenue_delta
- actions_count

Endpoints:
- GET /work-session
- POST /work-session/start
- POST /work-session/log
- POST /work-session/run-cycle
- POST /work-session/end

---

### v3.3 — Autonomous Concierge Decision Engine

Criado motor de decisão autônoma.

Funções:
- analisar response
- analisar delivery
- analisar task
- decidir auto_execute / auto_block / wait
- registrar confiança e risco

Tabela:
- concierge_decisions

Exemplos validados:
- response #3: block_duplicate_charge
- delivery #8: auto_release_delivery
- task #898: auto_send_outreach

---

### v3.3.1 — Autonomous Concierge Decision Executor

Criado executor de decisões.

Funções:
- executa decisões seguras
- bloqueia duplicidade
- marca delivery como ready_to_release
- prepara deal/outreach para task forte

Endpoints:
- GET /concierge/executor
- GET /concierge/executor.json
- POST /concierge/executor/run
- POST /concierge/executor/:id

---

### v3.3.2 — Batch limit fix

Correção:
- `run_batch(limit: 20)` corrigido para `run_batch(limit = 20)`.

---

### v3.3.3 — Proposals schema compatibility

Correção:
- executor não quebra se `proposals` não tiver coluna `value`.
- usa `suggested_price` se existir.
- se schema incompatível, cria deal sem proposal.

---

### v3.3.4 — Outreach schema compatibility

Correção:
- executor não quebra se `outreach_messages` não tiver coluna `body`.
- detecta coluna compatível:
  - body
  - message
  - content
  - text
  - message_body

Resultado:
- task #898 gerou deal #6.
- se deal já existe, não duplica.

---

### v3.4 — Follow-up & Payment Recovery Autopilot

Criado autopilot de follow-up.

Funções:
- detecta dinheiro parado
- detecta proposals abertas
- detecta respostas interessadas
- detecta deliveries prontas
- cria followup_tasks
- processa vencidos
- enfileira outreach_messages
- registra eventos

Endpoints:
- GET /followups/autopilot
- GET /followups/autopilot.json
- POST /followups/autopilot/scan
- POST /followups/autopilot/run-due
- POST /followups/autopilot/:id/process
- POST /followups/autopilot/:id/done
- POST /followups/autopilot/:id/lost

Resultado validado:
- Criou follow-ups para deals #3, #4, #5, #6.
- Criou follow-ups para responses #1 e #2.
- Criou follow-up para delivery #8.
- Enfileirou outreach #3 a #8.

---

### v3.5 — Safe Dispatch Autopilot

Criado autopilot de dispatch seguro.

Funções:
- lê outreach_messages queued
- respeita policy_status approved
- respeita CHANNEL_DISPATCH_ENABLED
- respeita limite diário
- respeita janela de envio
- evita dispatch duplicado
- cria channel_dispatches
- registra dispatch_autopilot_events

Endpoints:
- GET /dispatch/autopilot
- GET /dispatch/autopilot.json
- POST /dispatch/autopilot/run
- POST /dispatch/autopilot/:id/process

Resultado validado:
- 7 candidatas
- 2 foram para manual_channel
- 5 bloqueadas por limite diário
- 0 falhas

---

### v3.5.1 — Dispatch Recipient Resolver

Criado resolvedor de destinatário.

Funções:
- resolve por contact_id
- resolve por deal
- resolve por response
- resolve por task/raw_json
- registra recipient_resolved
- reduz missing_recipient

Resultado validado:
- outreach #5 resolveu recipient: borgesrenan263@gmail.com
- criou manual_channel com recipient preenchido quando dispatch real estava desligado.

---

### v3.5.2 — Dispatch Limit Order Fix

Correção:
- resolve destinatário antes de checar limite diário.
- se limite está cheio, marca:
  recipient_resolved_waiting_limit

Resultado validado:
- outreach #8:
  recipient_resolved_waiting_limit
  recipient: borgesrenan263@gmail.com
  sem criar novo dispatch.

---

## 5. Estado atual do sistema

Versão operacional atual:

v3.5.2

Esteira atual:

1. Coleta oportunidades
2. Cria entregas/propostas
3. Concierge decide
4. Executor executa decisões seguras
5. Follow-up Autopilot cria follow-ups
6. Dispatch Autopilot processa fila
7. Recipient Resolver resolve destinatário
8. Limites e segurança bloqueiam excessos
9. Monitoring/Uptime acompanha

---

## 6. Próximo passo planejado

v3.6 — Autopilot Daily Loop

Objetivo:
unificar tudo em um ciclo operacional único.

Fluxo desejado:

1. scan follow-ups
2. run due follow-ups
3. run concierge executor
4. run safe dispatch
5. update monitoring heartbeat
6. registrar cycle summary
7. aparecer no Command Center

Arquivos prováveis:

- db/add_autopilot_daily_loop.rb
- app/services/ops/autopilot_daily_loop_engine.rb
- app/routes/autopilot_daily_loop_routes.rb
- app/views/autopilot_daily_loop.erb

Endpoint provável:

- GET /autopilot/daily-loop
- GET /autopilot/daily-loop.json
- POST /autopilot/daily-loop/run

---

## 7. Pendências conhecidas

- Dispatch real está seguro, mas geralmente CHANNEL_DISPATCH_ENABLED=false.
- Algumas mensagens ainda ficam queued por limite diário.
- Algumas responses não têm deal/contact vinculado.
- O sistema ainda não deve disparar abordagem externa agressiva.
- Ainda falta daily loop único.
- Ainda falta worker automático para daily loop.
- Ainda falta relatório diário consolidado.
- Ainda falta limpeza automática de duplicatas antigas.

---

## 8. Comandos de saúde

Health:

curl -s http://127.0.0.1:4567/uptime

Monitoring:

curl -b /tmp/sistema_cookie.txt -s http://127.0.0.1:4567/ops/monitoring.json | head

Command Center:

curl -b /tmp/sistema_cookie.txt -s http://127.0.0.1:4567/command-center.json | head

Finance:

curl -b /tmp/sistema_cookie.txt -s http://127.0.0.1:4567/finance/metrics.json | head

Follow-ups:

curl -b /tmp/sistema_cookie.txt -s http://127.0.0.1:4567/followups/autopilot.json | head

Dispatch:

curl -b /tmp/sistema_cookie.txt -s http://127.0.0.1:4567/dispatch/autopilot.json | head

---

## 9. Regras de segurança atuais

- Não criar cobrança duplicada se já existe payment paid.
- Não liberar entrega sem validação/pagamento.
- Não duplicar deals por task.
- Não duplicar channel_dispatches por outreach.
- Não enviar fora de janela.
- Não passar limite diário.
- Se não houver recipient, cair para manual_channel.
- Se dispatch real estiver desligado, cair para manual_channel.
- Se limite cheio, manter queued.

---

## 10. Último checkpoint validado

Última validação forte:

v3.5.2

Outreach #8:
- contact_id=1
- recipient resolvido
- limite diário atingido
- dispatch não criado
- status: recipient_resolved_waiting_limit

Tags recentes:
- v3.5.2
- v3.5.1
- v3.5
- v3.4
- v3.3.4
