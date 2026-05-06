require "time"

require_relative "../revenue/followup_autopilot_engine"
require_relative "../channels/dispatch_autopilot_engine"

class SalesPolicyDecisionExecutor
  def initialize(db)
    @db = db
  end

  def run_batch(limit: 20)
    decisions = pending_decisions(limit: limit)
    decisions.map { |decision| execute(decision) }
  end

  def execute(decision)
    return skip(decision, "decision_not_auto_execute") unless decision["decision"].to_s == "auto_execute"

    case decision["action_taken"].to_s
    when "auto_followup_proposal"
      execute_followup(decision)

    when "auto_prepare_payment"
      execute_prepare_payment(decision)

    when "auto_dispatch_outreach"
      execute_dispatch(decision)

    else
      skip(decision, "unsupported_sales_policy_action=#{decision["action_taken"]}")
    end
  rescue => e
    fail_decision(decision, "#{e.class}: #{e.message}")
  end

  private

  def pending_decisions(limit:)
    rows(
      <<~SQL,
        SELECT *
        FROM concierge_decisions
        WHERE decision_type LIKE 'sales_policy_%'
          AND execution_status = 'pending'
        ORDER BY confidence DESC, id ASC
        LIMIT ?
      SQL
      [limit]
    )
  end

  def execute_followup(decision)
    engine = FollowupAutopilotEngine.new(@db)

    scan_result = engine.scan
    run_result = engine.run_due

    mark_executed(
      decision,
      "sales_policy_followup_executed",
      "Follow-up autopilot executado. scan=#{safe_inspect(scan_result)} run_due=#{safe_inspect(run_result)}"
    )
  end

  def execute_prepare_payment(decision)
    deal_id = decision["entity_id"].to_i
    deal = row("SELECT * FROM deals WHERE id = ?", [deal_id])

    return skip(decision, "deal_not_found") unless deal

    paid = row(
      "SELECT * FROM payments WHERE deal_id = ? AND status = 'paid' LIMIT 1",
      [deal_id]
    )

    if paid
      return block_decision(
        decision,
        "payment_already_paid",
        "Deal ##{deal_id} já possui pagamento pago. Payment ##{paid["id"]}."
      )
    end

    existing = row(
      "SELECT * FROM payments WHERE deal_id = ? AND status = 'pending' LIMIT 1",
      [deal_id]
    )

    if existing
      return skip(
        decision,
        "pending_payment_already_exists",
        "Payment pending ##{existing["id"]} já existe para deal ##{deal_id}."
      )
    end

    now = Time.now.utc.iso8601
    amount = deal["value"].to_f
    reference = "deal-#{deal_id}"

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
          external_reference,
          created_at,
          updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        deal_id,
        deal["task_id"],
        amount,
        "pix_manual",
        "PIX configurado",
        "pending",
        reference,
        "sales_policy",
        reference,
        now,
        now
      ]
    )

    payment_id = @db.last_insert_row_id

    update_deal_next_action(
      deal_id,
      "Cobrança Pix pending criada automaticamente pela Sales Policy. Payment ##{payment_id}."
    )

    mark_executed(
      decision,
      "payment_prepared",
      "Cobrança pending criada para deal ##{deal_id}. Payment ##{payment_id}. Valor R$ #{format("%.2f", amount)}."
    )
  end

  def execute_dispatch(decision)
    outreach_id = decision["entity_id"].to_i

    unless row("SELECT * FROM outreach_messages WHERE id = ?", [outreach_id])
      return skip(decision, "outreach_not_found")
    end

    result = DispatchAutopilotEngine.new(@db).process_one(outreach_id)

    status = result[:status].to_s rescue ""
    reason = result[:reason].to_s rescue result.inspect

    case status
    when "blocked"
      block_decision(decision, "dispatch_blocked", "Dispatch bloqueado: #{reason}")
    when "skipped"
      skip(decision, "dispatch_skipped", "Dispatch ignorado: #{reason}")
    else
      mark_executed(decision, "dispatch_processed", "Dispatch processado: #{safe_inspect(result)}")
    end
  end

  def update_deal_next_action(deal_id, message)
    @db.execute(
      "UPDATE deals SET next_action = ?, updated_at = ? WHERE id = ?",
      [message, Time.now.utc.iso8601, deal_id]
    )
  rescue
    nil
  end

  def mark_executed(decision, action, result)
    update_decision(decision["id"], "executed", action, result)
    { id: decision["id"], status: "executed", action: action, result: result }
  end

  def skip(decision, action, result = nil)
    result ||= action
    update_decision(decision["id"], "skipped", action, result)
    { id: decision["id"], status: "skipped", action: action, result: result }
  end

  def block_decision(decision, action, result)
    update_decision(decision["id"], "blocked", action, result)
    { id: decision["id"], status: "blocked", action: action, result: result }
  end

  def fail_decision(decision, error)
    update_decision(decision["id"], "failed", "sales_policy_execution_failed", error)
    { id: decision["id"], status: "failed", error: error }
  end

  def update_decision(id, status, action, result)
    now = Time.now.utc.iso8601

    @db.execute(
      <<~SQL,
        UPDATE concierge_decisions
        SET execution_status = ?,
            action_taken = ?,
            execution_result = ?,
            executed_at = ?
        WHERE id = ?
      SQL
      [status, action, result.to_s, now, id]
    )
  end

  def rows(sql, params = [])
    @db.execute(sql, params).map { |r| clean(r) }
  rescue
    []
  end

  def row(sql, params = [])
    clean(@db.get_first_row(sql, params))
  rescue
    nil
  end

  def clean(row)
    row&.reject { |k, _| k.is_a?(Integer) }
  end

  def safe_inspect(value)
    value.inspect[0, 500]
  rescue
    value.to_s[0, 500]
  end
end
