# COMANDOS RÁPIDOS DE TESTE

Sempre usar em blocos separados.

---

## Login

```bash
cd /root/projetos/sistema-autonomo

curl -s -i -c /tmp/sistema_cookie.txt \
  -X POST http://127.0.0.1:4567/login \
  -d "username=admin&password=admin123" | head -n 10
```

---

## Health

```bash
curl -s http://127.0.0.1:4567/uptime
echo
```

---

## Reiniciar servidor

```bash
pkill -9 -f "ruby app.rb" || true
pkill -9 -f "puma" || true

nohup ruby app.rb > storage/logs/server.log 2>&1 &
```

Depois separado:

```bash
sleep 3
tail -n 40 storage/logs/server.log
```

---

## Command Center

```bash
curl -b /tmp/sistema_cookie.txt \
  -s http://127.0.0.1:4567/command-center.json | head
```

---

## Monitoring

```bash
curl -b /tmp/sistema_cookie.txt \
  -s http://127.0.0.1:4567/ops/monitoring.json | head
```

---

## Finance

```bash
curl -b /tmp/sistema_cookie.txt \
  -s http://127.0.0.1:4567/finance/metrics.json | head
```

---

## Follow-up Autopilot

```bash
curl -b /tmp/sistema_cookie.txt \
  -X POST http://127.0.0.1:4567/followups/autopilot/scan -i | head -n 20

curl -b /tmp/sistema_cookie.txt \
  -X POST http://127.0.0.1:4567/followups/autopilot/run-due -i | head -n 20

sqlite3 data/sistema_autonomo.sqlite3 "select id, entity_type, entity_id, followup_type, status, priority, attempts, max_attempts, last_error from followup_tasks order by id desc limit 20;"
```

---

## Dispatch Autopilot

```bash
curl -b /tmp/sistema_cookie.txt \
  -X POST http://127.0.0.1:4567/dispatch/autopilot/run -i | head -n 20

sqlite3 data/sistema_autonomo.sqlite3 "select id, status, total_candidates, sent_count, manual_count, blocked_count, failed_count, summary from dispatch_autopilot_runs order by id desc limit 10;"

sqlite3 data/sistema_autonomo.sqlite3 "select id, run_id, outreach_message_id, dispatch_id, event_type, status, reason from dispatch_autopilot_events order by id desc limit 20;"

sqlite3 data/sistema_autonomo.sqlite3 "select id, deal_id, contact_id, status, policy_status, subject, dispatch_autopilot_status, dispatch_autopilot_note from outreach_messages order by id desc limit 20;"
```

---

## Concierge Executor

```bash
curl -b /tmp/sistema_cookie.txt \
  -X POST http://127.0.0.1:4567/concierge/executor/run -i | head -n 20

sqlite3 data/sistema_autonomo.sqlite3 "select id, entity_type, entity_id, decision_type, decision, execution_status, action_taken, execution_result from concierge_decisions order by id desc limit 20;"
```

---

## Tags recentes

```bash
git log --oneline --decorate -10
```
