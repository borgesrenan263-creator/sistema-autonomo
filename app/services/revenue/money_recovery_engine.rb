require "time"

class MoneyRecoveryEngine
  def initialize(db)
    @db = db
  end

  def snapshot
    proposal_deals = rows(%{
      SELECT *
      FROM deals
      WHERE status IN ('proposta_criada', 'interessado')
      ORDER BY value DESC, id DESC
      LIMIT 30
    })

    pending_payments = rows(%{
      SELECT *
      FROM payments
      WHERE status = 'pending'
      ORDER BY amount DESC, id DESC
      LIMIT 30
    })

    ready_deliveries = rows(%{
      SELECT *
      FROM deliveries
      WHERE validation_status = 'validated'
        AND release_status IN ('ready_to_release', 'ready', 'pending')
      ORDER BY id DESC
      LIMIT 30
    }) rescue []

    pending_followups = rows(%{
      SELECT *
      FROM followup_tasks
      WHERE status IN ('pending', 'queued')
      ORDER BY priority DESC, id DESC
      LIMIT 30
    }) rescue []

    stuck_outreach = rows(%{
      SELECT *
      FROM outreach_messages
      WHERE status = 'queued'
        AND policy_status = 'approved'
        AND (
          dispatch_autopilot_status IS NULL
          OR dispatch_autopilot_status IN ('queued', 'recipient_resolved_waiting_limit')
        )
      ORDER BY id DESC
      LIMIT 30
    }) rescue []

    totals = {
      proposal_pipeline: sum_values(proposal_deals, "value"),
      pending_payments: sum_values(pending_payments, "amount"),
      ready_deliveries: ready_deliveries.size,
      pending_followups: pending_followups.size,
      stuck_outreach: stuck_outreach.size
    }

    totals[:money_at_risk] = totals[:proposal_pipeline].to_f + totals[:pending_payments].to_f

    {
      generated_at: Time.now.utc.iso8601,
      totals: totals,
      next_action: next_action(totals, proposal_deals, pending_payments, ready_deliveries, pending_followups, stuck_outreach),
      proposal_deals: proposal_deals,
      pending_payments: pending_payments,
      ready_deliveries: ready_deliveries,
      pending_followups: pending_followups,
      stuck_outreach: stuck_outreach
    }
  end

  private

  def next_action(totals, proposal_deals, pending_payments, ready_deliveries, pending_followups, stuck_outreach)
    if pending_payments.any?
      payment = pending_payments.first
      return {
        title: "Recuperar pagamento pendente",
        detail: "Existe cobrança pending de R$ #{money(payment["amount"])} no deal ##{payment["deal_id"]}.",
        priority: 95,
        action: "payment_recovery"
      }
    end

    if ready_deliveries.any?
      delivery = ready_deliveries.first
      return {
        title: "Liberar entrega pronta",
        detail: "Delivery ##{delivery["id"]} está validada/pronta para liberação.",
        priority: 90,
        action: "release_delivery"
      }
    end

    if proposal_deals.any?
      deal = proposal_deals.first
      return {
        title: "Mover proposta aberta",
        detail: "Deal ##{deal["id"]} tem R$ #{money(deal["value"])} parado em #{deal["status"]}.",
        priority: 85,
        action: "proposal_followup"
      }
    end

    if pending_followups.any?
      followup = pending_followups.first
      return {
        title: "Processar follow-up",
        detail: "Follow-up ##{followup["id"]} está pendente.",
        priority: 75,
        action: "run_followup"
      }
    end

    if stuck_outreach.any?
      outreach = stuck_outreach.first
      return {
        title: "Resolver abordagem travada",
        detail: "Outreach ##{outreach["id"]} está aguardando dispatch/manual.",
        priority: 70,
        action: "resolve_outreach"
      }
    end

    {
      title: "Nenhum dinheiro parado crítico",
      detail: "Pipeline sem pendências críticas neste momento.",
      priority: 10,
      action: "monitor"
    }
  end

  def money(value)
    format("%.2f", value.to_f)
  end

  def sum_values(rows, key)
    rows.map { |r| r[key].to_f }.sum.round(2)
  end

  def rows(sql, params = [])
    @db.execute(sql, params).map { |row| clean(row) }
  rescue
    []
  end

  def clean(row)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
