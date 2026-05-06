require "time"
require "json"

class ConciergeDecisionEngine
  def initialize(db)
    @db = db
  end

  def dashboard
    {
      generated_at: Time.now.iso8601,
      counts: counts,
      rules: rules,
      latest_decisions: latest_decisions,
      candidates: {
        responses: response_candidates,
        payments: payment_candidates,
        deliveries: delivery_candidates,
        opportunities: opportunity_candidates
      }
    }
  end

  def evaluate_response(event_id)
    event = one("SELECT * FROM response_inbox_events WHERE id = ?", [event_id])
    raise "Response event não encontrado" unless event

    deal = event["deal_id"] ? one("SELECT * FROM deals WHERE id = ?", [event["deal_id"]]) : nil
    paid = deal ? one("SELECT * FROM payments WHERE deal_id = ? AND status = 'paid' ORDER BY id DESC LIMIT 1", [deal["id"]]) : nil
    pending = deal ? one("SELECT * FROM payments WHERE deal_id = ? AND status = 'pending' ORDER BY id DESC LIMIT 1", [deal["id"]]) : nil

    confidence = 50
    reasons = []

    if event["response_status"].to_s == "interested"
      confidence += 25
      reasons << "resposta marcada como interested"
    end

    if event["signature_valid"].to_i == 1
      confidence += 10
      reasons << "assinatura válida"
    else
      confidence -= 25
      reasons << "assinatura inválida ou ausente"
    end

    if deal
      confidence += 15
      reasons << "deal vinculado"
    else
      confidence -= 30
      reasons << "sem deal vinculado"
    end

    if paid
      confidence = 100
      decision = "auto_block"
      risk = "low"
      decision_type = "block_duplicate_charge"
      reason = "Deal já possui pagamento confirmado. Cobrança bloqueada automaticamente."
      action = "blocked_duplicate_charge"
    elsif pending
      confidence += 5
      decision = confidence >= threshold("auto_create_charge") ? "auto_wait" : "auto_block"
      risk = confidence >= 75 ? "low" : "medium"
      decision_type = "auto_create_charge"
      reason = "Já existe cobrança pendente para este deal."
      action = "wait_existing_payment"
    else
      decision_type = "auto_create_charge"
      decision = confidence >= threshold("auto_create_charge") ? "auto_execute" : "auto_block"
      risk = confidence >= 80 ? "low" : confidence >= 65 ? "medium" : "high"
      reason = reasons.join("; ")
      action = decision == "auto_execute" ? "can_create_charge" : "blocked_low_confidence"
    end

    record_decision(
      entity_type: "response",
      entity_id: event_id,
      decision_type: decision_type,
      decision: decision,
      confidence: clamp(confidence),
      risk_level: risk,
      reason: reason,
      action_taken: action,
      metadata: {
        deal_id: deal && deal["id"],
        paid_payment_id: paid && paid["id"],
        pending_payment_id: pending && pending["id"],
        response_status: event["response_status"],
        signature_valid: event["signature_valid"]
      }
    )
  end

  def evaluate_delivery(delivery_id)
    delivery = one("SELECT * FROM deliveries WHERE id = ?", [delivery_id])
    raise "Delivery não encontrada" unless delivery

    validation_score = delivery["validation_score"].to_i
    sandbox = one(
      "SELECT * FROM validation_sandbox_runs WHERE delivery_id = ? ORDER BY id DESC LIMIT 1",
      [delivery_id]
    )

    payment = one(
      "SELECT * FROM payments WHERE task_id = ? AND status = 'paid' ORDER BY id DESC LIMIT 1",
      [delivery["task_id"]]
    )

    confidence = validation_score
    reasons = ["validation_score=#{validation_score}"]

    if sandbox && sandbox["status"].to_s == "passed"
      confidence += 20
      reasons << "sandbox passed"
    elsif sandbox && sandbox["status"].to_s == "failed"
      confidence -= 35
      reasons << "sandbox failed"
    elsif sandbox && sandbox["status"].to_s == "manual_review"
      confidence -= 20
      reasons << "sandbox manual_review"
    else
      confidence -= 10
      reasons << "sem sandbox conclusivo"
    end

    if payment
      confidence += 10
      reasons << "pagamento confirmado"
    else
      confidence -= 20
      reasons << "sem pagamento confirmado"
    end

    if confidence >= threshold("auto_release_delivery")
      decision = "auto_execute"
      risk = "low"
      action = "can_release_delivery"
      decision_type = "auto_release_delivery"
    elsif confidence < threshold("block_low_confidence_delivery")
      decision = "auto_block"
      risk = "high"
      action = "blocked_low_confidence_delivery"
      decision_type = "block_low_confidence_delivery"
    else
      decision = "auto_wait"
      risk = "medium"
      action = "wait_more_validation"
      decision_type = "auto_release_delivery"
    end

    record_decision(
      entity_type: "delivery",
      entity_id: delivery_id,
      decision_type: decision_type,
      decision: decision,
      confidence: clamp(confidence),
      risk_level: risk,
      reason: reasons.join("; "),
      action_taken: action,
      metadata: {
        task_id: delivery["task_id"],
        validation_status: delivery["validation_status"],
        validation_score: validation_score,
        sandbox_status: sandbox && sandbox["status"],
        payment_id: payment && payment["id"]
      }
    )
  end

  def evaluate_opportunity(task_id)
    task = one("SELECT * FROM tasks WHERE id = ?", [task_id])
    raise "Task não encontrada" unless task

    confidence = 40
    reasons = []

    demand_score = task["demand_score"].to_i
    suggested_price = money(task["suggested_price"] || 0)
    quality_status = task["quality_status"].to_s
    status = task["status"].to_s
    url = task["url"].to_s

    confidence += demand_score * 4
    reasons << "demand_score=#{demand_score}"

    if quality_status == "monetizable"
      confidence += 20
      reasons << "monetizable"
    elsif quality_status == "ignore"
      confidence -= 40
      reasons << "quality ignore"
    end

    if suggested_price >= 500
      confidence += 10
      reasons << "ticket >= 500"
    end

    if url.include?("github.com")
      confidence += 8
      reasons << "github context"
    end

    duplicate = one(
      "SELECT * FROM deals WHERE task_id = ? ORDER BY id DESC LIMIT 1",
      [task_id]
    )

    if duplicate
      confidence -= 25
      reasons << "deal já existe"
    end

    if status == "ok" || status == "filtragem"
      confidence += 5
      reasons << "status operacional bom"
    end

    decision =
      if duplicate
        "auto_skip"
      elsif confidence >= threshold("auto_send_outreach")
        "auto_execute"
      elsif confidence >= 65
        "auto_wait"
      else
        "auto_block"
      end

    risk = confidence >= 82 ? "low" : confidence >= 65 ? "medium" : "high"
    action = decision == "auto_execute" ? "can_prepare_outreach" : decision == "auto_skip" ? "skip_duplicate" : "not_ready"

    record_decision(
      entity_type: "task",
      entity_id: task_id,
      decision_type: "auto_send_outreach",
      decision: decision,
      confidence: clamp(confidence),
      risk_level: risk,
      reason: reasons.join("; "),
      action_taken: action,
      metadata: {
        demand_score: demand_score,
        suggested_price: suggested_price,
        quality_status: quality_status,
        status: status,
        duplicate_deal_id: duplicate && duplicate["id"]
      }
    )
  end

  def run_batch(limit: 20)
    results = []

    response_candidates.first(limit).each do |item|
      results << evaluate_response(item["id"])
    rescue => e
      results << { error: e.message, entity: "response", id: item["id"] }
    end

    delivery_candidates.first(limit).each do |item|
      results << evaluate_delivery(item["id"])
    rescue => e
      results << { error: e.message, entity: "delivery", id: item["id"] }
    end

    opportunity_candidates.first(limit).each do |item|
      results << evaluate_opportunity(item["id"])
    rescue => e
      results << { error: e.message, entity: "task", id: item["id"] }
    end

    results
  end

  private

  def response_candidates
    return [] unless table_exists?("response_inbox_events")

    all(
      <<~SQL
        SELECT *
        FROM response_inbox_events
        WHERE response_status = 'interested'
        ORDER BY id DESC
        LIMIT 50
      SQL
    )
  end

  def payment_candidates
    return [] unless table_exists?("payments")

    all(
      <<~SQL
        SELECT *
        FROM payments
        WHERE status = 'pending'
        ORDER BY id DESC
        LIMIT 50
      SQL
    )
  end

  def delivery_candidates
    return [] unless table_exists?("deliveries")

    all(
      <<~SQL
        SELECT *
        FROM deliveries
        WHERE validation_status IN ('validated', 'manual_review')
        ORDER BY id DESC
        LIMIT 50
      SQL
    )
  end

  def opportunity_candidates
    return [] unless table_exists?("tasks")

    all(
      <<~SQL
        SELECT *
        FROM tasks
        WHERE quality_status IN ('monetizable', 'review')
        ORDER BY id DESC
        LIMIT 50
      SQL
    )
  end

  def counts
    {
      total: scalar("SELECT COUNT(*) FROM concierge_decisions"),
      auto_execute: scalar("SELECT COUNT(*) FROM concierge_decisions WHERE decision = 'auto_execute'"),
      auto_block: scalar("SELECT COUNT(*) FROM concierge_decisions WHERE decision = 'auto_block'"),
      auto_skip: scalar("SELECT COUNT(*) FROM concierge_decisions WHERE decision = 'auto_skip'"),
      auto_wait: scalar("SELECT COUNT(*) FROM concierge_decisions WHERE decision = 'auto_wait'")
    }
  rescue
    {}
  end

  def latest_decisions
    all("SELECT * FROM concierge_decisions ORDER BY id DESC LIMIT 100")
  rescue
    []
  end

  def rules
    all("SELECT * FROM concierge_policy_rules ORDER BY rule_key ASC")
  rescue
    []
  end

  def threshold(rule_key)
    rule = one("SELECT * FROM concierge_policy_rules WHERE rule_key = ?", [rule_key])
    return 70 unless rule
    return 70 if rule["enabled"].to_i != 1

    rule["threshold"].to_i
  end

  def record_decision(entity_type:, entity_id:, decision_type:, decision:, confidence:, risk_level:, reason:, action_taken:, metadata: {})
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        INSERT INTO concierge_decisions
        (
          entity_type,
          entity_id,
          decision_type,
          decision,
          confidence,
          risk_level,
          reason,
          action_taken,
          metadata,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        entity_type,
        entity_id,
        decision_type,
        decision,
        confidence,
        risk_level,
        reason,
        action_taken,
        JSON.generate(metadata || {}),
        now
      ]
    )

    one("SELECT * FROM concierge_decisions WHERE id = ?", [@db.last_insert_row_id])
  end

  def table_exists?(name)
    !!one("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [name])
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

  def clamp(value)
    [[value.to_i, 0].max, 100].min
  end
end
