require "time"
require "json"

class ConciergeDecisionExecutor
  def initialize(db)
    @db = db
  end

  def dashboard
    {
      generated_at: Time.now.iso8601,
      counts: counts,
      pending_decisions: pending_decisions,
      latest_events: latest_events
    }
  end

  def run_batch(limit = 20)
    pending_decisions.first(limit).map do |decision|
      execute(decision["id"])
    rescue => e
      {
        decision_id: decision["id"],
        error: "#{e.class}: #{e.message}"
      }
    end
  end

  def execute(decision_id)
    decision = one("SELECT * FROM concierge_decisions WHERE id = ?", [decision_id])
    raise "Decision não encontrada" unless decision

    return decision if decision["execution_status"].to_s == "executed"
    return decision if decision["execution_status"].to_s == "blocked"

    result =
      case decision["decision_type"].to_s
      when "block_duplicate_charge"
        execute_block_duplicate_charge(decision)
      when "auto_create_charge"
        execute_auto_create_charge(decision)
      when "auto_release_delivery"
        execute_auto_release_delivery(decision)
      when "auto_send_outreach"
        execute_auto_send_outreach(decision)
      else
        mark_execution(decision, "skipped", "Tipo de decisão sem executor ativo.", "no_executor")
      end

    result
  end

  private

  def execute_block_duplicate_charge(decision)
    event = one("SELECT * FROM response_inbox_events WHERE id = ?", [decision["entity_id"]])

    unless event
      return mark_execution(decision, "failed", "Response event não encontrado.", "missing_response")
    end

    deal_id = event["deal_id"]
    paid = deal_id ? one("SELECT * FROM payments WHERE deal_id = ? AND status = 'paid' ORDER BY id DESC LIMIT 1", [deal_id]) : nil

    unless paid
      return mark_execution(decision, "skipped", "Nenhum pagamento paid encontrado; bloqueio não aplicado.", "no_paid_payment")
    end

    if table_has_column?("response_inbox_events", "action_status")
      @db.execute(
        <<~SQL,
          UPDATE response_inbox_events
          SET action_status = ?,
              action_note = ?,
              actioned_at = ?
          WHERE id = ?
        SQL
        [
          "already_paid",
          "Concierge bloqueou cobrança duplicada. Payment ##{paid["id"]} já está pago.",
          Time.now.iso8601,
          event["id"]
        ]
      )
    end

    record_response_action(event, "already_paid", "Concierge bloqueou cobrança duplicada. Payment ##{paid["id"]} já está pago.")

    mark_execution(
      decision,
      "blocked",
      "Cobrança duplicada bloqueada automaticamente. Payment ##{paid["id"]} já pago.",
      "duplicate_charge_blocked"
    )
  end

  def execute_auto_create_charge(decision)
    return mark_execution(decision, "skipped", "Decisão não é auto_execute.", "not_auto_execute") unless decision["decision"].to_s == "auto_execute"

    event = one("SELECT * FROM response_inbox_events WHERE id = ?", [decision["entity_id"]])
    return mark_execution(decision, "failed", "Response event não encontrado.", "missing_response") unless event

    deal = event["deal_id"] ? one("SELECT * FROM deals WHERE id = ?", [event["deal_id"]]) : nil
    return mark_execution(decision, "failed", "Deal não encontrado.", "missing_deal") unless deal

    paid = one("SELECT * FROM payments WHERE deal_id = ? AND status = 'paid' ORDER BY id DESC LIMIT 1", [deal["id"]])
    if paid
      return mark_execution(decision, "blocked", "Deal já pago. Payment ##{paid["id"]}.", "already_paid")
    end

    pending = one("SELECT * FROM payments WHERE deal_id = ? AND status = 'pending' ORDER BY id DESC LIMIT 1", [deal["id"]])

    if pending
      payment = pending
      result = "Cobrança pending já existia. Payment ##{payment["id"]}."
    else
      now = Time.now.iso8601
      amount = money(deal["value"] || deal["amount"] || 0)
      amount = 720 if amount <= 0

      @db.execute(
        <<~SQL,
          INSERT INTO payments
          (
            deal_id,
            task_id,
            amount,
            method,
            pix_label,
            status,
            reference,
            provider,
            created_at,
            updated_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [
          deal["id"],
          deal["task_id"],
          amount,
          "pix_manual",
          "PIX configurado",
          "pending",
          "deal-#{deal["id"]}",
          "pix_manual",
          now,
          now
        ]
      )

      payment = one("SELECT * FROM payments WHERE id = ?", [@db.last_insert_row_id])
      result = "Cobrança criada automaticamente. Payment ##{payment["id"]}."
    end

    if table_has_column?("response_inbox_events", "action_status")
      @db.execute(
        <<~SQL,
          UPDATE response_inbox_events
          SET action_status = ?,
              action_note = ?,
              actioned_at = ?
          WHERE id = ?
        SQL
        [
          "charge_created",
          "Concierge criou/identificou cobrança automaticamente. Payment ##{payment["id"]}.",
          Time.now.iso8601,
          event["id"]
        ]
      )
    end

    record_response_action(event, "charge_created", "Concierge criou/identificou cobrança automaticamente. Payment ##{payment["id"]}.")

    mark_execution(decision, "executed", result, "charge_created")
  end

  def execute_auto_release_delivery(decision)
    return mark_execution(decision, "skipped", "Decisão não é auto_execute.", "not_auto_execute") unless decision["decision"].to_s == "auto_execute"

    delivery = one("SELECT * FROM deliveries WHERE id = ?", [decision["entity_id"]])
    return mark_execution(decision, "failed", "Delivery não encontrada.", "missing_delivery") unless delivery

    now = Time.now.iso8601

    if table_has_column?("deliveries", "release_status")
      @db.execute(
        <<~SQL,
          UPDATE deliveries
          SET release_status = ?,
              release_note = ?,
              released_at = ?
          WHERE id = ?
        SQL
        [
          "ready_to_release",
          "Concierge marcou como pronta para liberação automática controlada.",
          now,
          delivery["id"]
        ]
      )
    end

    mark_execution(
      decision,
      "executed",
      "Delivery ##{delivery["id"]} marcada como ready_to_release.",
      "delivery_ready_to_release"
    )
  end

  def execute_auto_send_outreach(decision)
    return mark_execution(decision, "skipped", "Decisão não é auto_execute.", "not_auto_execute") unless decision["decision"].to_s == "auto_execute"

    task = one("SELECT * FROM tasks WHERE id = ?", [decision["entity_id"]])
    return mark_execution(decision, "failed", "Task não encontrada.", "missing_task") unless task

    existing = one(
      "SELECT * FROM deals WHERE task_id = ? ORDER BY id DESC LIMIT 1",
      [task["id"]]
    )

    if existing
      return mark_execution(
        decision,
        "skipped",
        "Deal já existe para task ##{task["id"]}. Deal ##{existing["id"]}.",
        "deal_already_exists"
      )
    end

    now = Time.now.iso8601
    value = money(task["suggested_price"] || 0)
    value = 720 if value <= 0

    proposal_id = nil
    contact_id = nil

    if table_exists?("proposals")
      @db.execute(
        <<~SQL,
          INSERT INTO proposals
          (
            task_id,
            status,
            value,
            notes,
            created_at,
            updated_at
          )
          VALUES (?, ?, ?, ?, ?, ?)
        SQL
        [
          task["id"],
          "draft",
          value,
          "Proposta preparada automaticamente pelo Concierge Decision Executor.",
          now,
          now
        ]
      )
      proposal_id = @db.last_insert_row_id
    end

    if table_exists?("contacts")
      contact = one("SELECT * FROM contacts WHERE platform = ? AND handle = ? LIMIT 1", ["GitHub", task["source"].to_s])
      contact_id = contact && contact["id"]
    end

    @db.execute(
      <<~SQL,
        INSERT INTO deals
        (
          task_id,
          proposal_id,
          contact_id,
          status,
          value,
          next_action,
          notes,
          created_at,
          updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        task["id"],
        proposal_id,
        contact_id,
        "proposta_criada",
        value,
        "Concierge preparou abordagem. Aguardando dispatch seguro.",
        "Deal criado automaticamente a partir de decisão auto_execute.",
        now,
        now
      ]
    )

    deal_id = @db.last_insert_row_id

    if table_exists?("outreach_messages")
      subject = "Diagnóstico objetivo sobre: #{task["title"]}"
      body = build_outreach_body(task, value)

      @db.execute(
        <<~SQL,
          INSERT INTO outreach_messages
          (
            flow_id,
            deal_id,
            contact_id,
            status,
            policy_status,
            subject,
            body,
            created_at,
            updated_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [
          nil,
          deal_id,
          contact_id,
          "queued",
          "approved",
          subject,
          body,
          now,
          now
        ]
      )
    end

    mark_execution(
      decision,
      "executed",
      "Deal ##{deal_id} preparado para task ##{task["id"]}; abordagem enfileirada se tabela existir.",
      "outreach_prepared"
    )
  end

  def build_outreach_body(task, value)
    <<~TXT.strip
      Olá, tudo bem?

      Identifiquei a issue "#{task["title"]}" e preparei um diagnóstico objetivo com plano de correção/validação.

      Posso seguir com uma proposta enxuta para resolver ou validar tecnicamente esse ponto.

      Valor sugerido: R$ #{format_money(value)} via Pix.

      Se fizer sentido, posso enviar os próximos passos.
    TXT
  end

  def mark_execution(decision, status, result, action_taken)
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        UPDATE concierge_decisions
        SET execution_status = ?,
            execution_result = ?,
            action_taken = ?,
            executed_at = ?
        WHERE id = ?
      SQL
      [
        status,
        result,
        action_taken,
        now,
        decision["id"]
      ]
    )

    @db.execute(
      <<~SQL,
        INSERT INTO concierge_execution_events
        (
          decision_id,
          entity_type,
          entity_id,
          execution_status,
          action_taken,
          result,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        decision["id"],
        decision["entity_type"],
        decision["entity_id"],
        status,
        action_taken,
        result,
        now
      ]
    )

    one("SELECT * FROM concierge_decisions WHERE id = ?", [decision["id"]])
  end

  def record_response_action(event, action_type, note)
    return unless table_exists?("response_actions")

    @db.execute(
      <<~SQL,
        INSERT INTO response_actions
        (
          response_event_id,
          deal_id,
          task_id,
          contact_id,
          action_type,
          status,
          note,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        event["id"],
        event["deal_id"],
        event["task_id"],
        event["contact_id"],
        action_type,
        "done",
        note,
        Time.now.iso8601
      ]
    )
  rescue
  end

  def counts
    {
      pending: scalar("SELECT COUNT(*) FROM concierge_decisions WHERE execution_status IS NULL OR execution_status = 'pending'"),
      executed: scalar("SELECT COUNT(*) FROM concierge_decisions WHERE execution_status = 'executed'"),
      blocked: scalar("SELECT COUNT(*) FROM concierge_decisions WHERE execution_status = 'blocked'"),
      skipped: scalar("SELECT COUNT(*) FROM concierge_decisions WHERE execution_status = 'skipped'"),
      failed: scalar("SELECT COUNT(*) FROM concierge_decisions WHERE execution_status = 'failed'")
    }
  rescue
    {}
  end

  def pending_decisions
    all(
      <<~SQL
        SELECT *
        FROM concierge_decisions
        WHERE execution_status IS NULL OR execution_status = 'pending'
        ORDER BY id DESC
        LIMIT 100
      SQL
    )
  rescue
    []
  end

  def latest_events
    all("SELECT * FROM concierge_execution_events ORDER BY id DESC LIMIT 100")
  rescue
    []
  end

  def table_exists?(name)
    !!one("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [name])
  rescue
    false
  end

  def table_has_column?(table, column)
    rows = @db.execute("PRAGMA table_info(#{table})")
    rows.any? do |row|
      if row.is_a?(Hash)
        row["name"].to_s == column.to_s
      else
        row[1].to_s == column.to_s
      end
    end
  rescue
    false
  end

  def scalar(sql, params = [])
    row = @db.get_first_row(sql, params)
    return row.values.first.to_i if row.is_a?(Hash)
    row.to_a.first.to_i
  rescue
    0
  end

  def one(sql, params = [])
    row = @db.get_first_row(sql, params)
    row&.reject { |k, _| k.is_a?(Integer) }
  end

  def all(sql, params = [])
    @db.execute(sql, params).map { |row| row.reject { |k, _| k.is_a?(Integer) } }
  end

  def money(value)
    value.to_s.gsub(/[^\d.,-]/, "").tr(",", ".").to_f
  end

  def format_money(value)
    "%.2f" % value.to_f
  end
end
