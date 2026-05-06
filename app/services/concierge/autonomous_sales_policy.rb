require "time"

class AutonomousSalesPolicy
  def initialize(db)
    @db = db
  end

  def run_once(limit: 20)
    decisions = []

    decisions += decide_open_deals(limit: limit)
    decisions += decide_pending_payments(limit: limit)
    decisions += decide_ready_deliveries(limit: limit)
    decisions += decide_stuck_outreach(limit: limit)

    decisions
  end

  private

  def decide_open_deals(limit:)
    rows(%{
      SELECT *
      FROM deals
      WHERE status IN ('proposta_criada', 'interessado')
      ORDER BY value DESC, id DESC
      LIMIT ?
    }, [limit]).map do |deal|
      next if decision_exists?("deal", deal["id"], "sales_policy_next_action")

      action =
        if deal["status"].to_s == "interessado"
          "auto_prepare_payment"
        else
          "auto_followup_proposal"
        end

      confidence = deal["status"].to_s == "interessado" ? 90 : 78

      create_decision(
        entity_type: "deal",
        entity_id: deal["id"],
        decision_type: "sales_policy_next_action",
        decision: "auto_execute",
        confidence: confidence,
        risk_level: "low",
        action_taken: action,
        reason: "deal_status=#{deal["status"]}; value=#{deal["value"]}; autonomous sales policy"
      )
    end.compact
  end

  def decide_pending_payments(limit:)
    rows(%{
      SELECT *
      FROM payments
      WHERE status = 'pending'
      ORDER BY amount DESC, id DESC
      LIMIT ?
    }, [limit]).map do |payment|
      next if decision_exists?("payment", payment["id"], "sales_policy_payment_recovery")

      create_decision(
        entity_type: "payment",
        entity_id: payment["id"],
        decision_type: "sales_policy_payment_recovery",
        decision: "auto_execute",
        confidence: 88,
        risk_level: "low",
        action_taken: "auto_recover_pending_payment",
        reason: "payment pending; amount=#{payment["amount"]}; deal_id=#{payment["deal_id"]}"
      )
    end.compact
  end

  def decide_ready_deliveries(limit:)
    rows(%{
      SELECT *
      FROM deliveries
      WHERE validation_status = 'validated'
        AND release_status IN ('ready_to_release', 'ready', 'pending')
      ORDER BY id DESC
      LIMIT ?
    }, [limit]).map do |delivery|
      next if decision_exists?("delivery", delivery["id"], "sales_policy_release_delivery")

      create_decision(
        entity_type: "delivery",
        entity_id: delivery["id"],
        decision_type: "sales_policy_release_delivery",
        decision: "auto_execute",
        confidence: 92,
        risk_level: "low",
        action_taken: "auto_release_delivery",
        reason: "delivery validated and ready; task_id=#{delivery["task_id"]}; release_status=#{delivery["release_status"]}"
      )
    end.compact
  end

  def decide_stuck_outreach(limit:)
    rows(%{
      SELECT *
      FROM outreach_messages
      WHERE status = 'queued'
        AND policy_status = 'approved'
        AND (
          dispatch_autopilot_status IS NULL
          OR dispatch_autopilot_status IN ('queued', 'manual', 'recipient_resolved_waiting_limit')
        )
      ORDER BY id DESC
      LIMIT ?
    }, [limit]).map do |outreach|
      next if decision_exists?("outreach", outreach["id"], "sales_policy_dispatch_outreach")

      risk = outreach["contact_id"].to_s.empty? ? "medium" : "low"
      decision = risk == "low" ? "auto_execute" : "needs_review"
      action = risk == "low" ? "auto_dispatch_outreach" : "resolve_missing_contact"

      create_decision(
        entity_type: "outreach",
        entity_id: outreach["id"],
        decision_type: "sales_policy_dispatch_outreach",
        decision: decision,
        confidence: risk == "low" ? 84 : 65,
        risk_level: risk,
        action_taken: action,
        reason: "outreach queued; policy approved; contact_id=#{outreach["contact_id"]}; dispatch_status=#{outreach["dispatch_autopilot_status"]}"
      )
    end.compact
  end

  def create_decision(entity_type:, entity_id:, decision_type:, decision:, confidence:, risk_level:, action_taken:, reason:)
    now = Time.now.utc.iso8601

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
          action_taken,
          reason,
          execution_status,
          created_at,
          updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        entity_type,
        entity_id,
        decision_type,
        decision,
        confidence,
        risk_level,
        action_taken,
        reason,
        "pending",
        now,
        now
      ]
    )

    id = @db.last_insert_row_id
    row("SELECT * FROM concierge_decisions WHERE id = ?", [id])
  end

  def decision_exists?(entity_type, entity_id, decision_type)
    !!row(
      %{
        SELECT id
        FROM concierge_decisions
        WHERE entity_type = ?
          AND entity_id = ?
          AND decision_type = ?
          AND decision IN ('auto_execute', 'needs_review', 'auto_block')
          AND execution_status IN ('pending', 'executed', 'blocked', 'skipped')
        LIMIT 1
      },
      [entity_type, entity_id, decision_type]
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
end
