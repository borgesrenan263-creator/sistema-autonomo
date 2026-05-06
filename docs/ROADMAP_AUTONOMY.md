# ROADMAP — AUTONOMIA DE RENDA

Meta:

95% automático.
Concierge decide e executa decisões seguras.
Usuário acompanha pelo Command Center.

---

## Fase atual

Estamos na transição:

v3.5.2 → v3.6

A esteira já faz:

- decisão
- execução
- follow-up
- dispatch seguro
- limite diário
- resolução de destinatário

Falta:

- um loop diário unificado
- agendamento contínuo
- resumo final do ciclo
- worker dedicado ao loop
- relatório diário de dinheiro parado

---

## Próximo grande bloco

## v3.6 — Autopilot Daily Loop

Função:

Rodar a operação inteira com um comando único.

Fluxo:

1. FollowupAutopilotEngine.scan
2. FollowupAutopilotEngine.run_due
3. ConciergeDecisionExecutor.run_batch
4. DispatchAutopilotEngine.run
5. OpsHeartbeat registra autopilot_daily_loop
6. Salva resumo em autopilot_daily_loop_runs

Resultado esperado:

- follow-ups criados
- follow-ups processados
- decisões executadas
- dispatch preparado
- heartbeat atualizado
- resumo salvo

---

## v3.6.1 — Worker integration

Rodar daily loop pelo worker.

Opções:

- job type: autopilot_daily_loop
- worker interval
- command center botão
- cron/manual local

---

## v3.6.2 — Cycle Summary Report

Gerar resumo:

- dinheiro parado antes/depois
- follow-ups criados
- mensagens enfileiradas
- dispatches criados
- bloqueios por limite
- cobranças recuperadas
- entregas liberadas

---

## v3.7 — Autopilot Policy Brain

Criar camada de política:

- quais tasks são boas
- quais tasks ignorar
- quais deals priorizar
- quando parar follow-up
- quando marcar perdido
- quando escalar para revisão

---

## v3.8 — Revenue Recovery Intelligence

Melhorar cobrança:

- detectar payment pending antigo
- gerar mensagem Pix específica
- priorizar por valor
- follow-up progressivo
- limitar tentativas
- marcar lost automaticamente

---

## v3.9 — Delivery Release Autopilot

Automatizar pós-pagamento:

- payment paid
- delivery validated
- sandbox passed
- release_status ready
- gerar mensagem final
- registrar entrega liberada

---

## v4.0 — Solo Autonomous Work OS

Objetivo:

Um painel com:

- iniciar ciclo
- ver dinheiro parado
- ver risco
- ver mensagens aguardando limite
- ver entregas prontas
- ver receita confirmada
- ver ações do Concierge
- ver próximo gargalo

Critério:

Sistema pode rodar uma sessão de trabalho com pouca intervenção.
