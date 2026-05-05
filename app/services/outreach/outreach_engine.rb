require "time"
require_relative "outreach_policy"
require_relative "outreach_builder"
require_relative "manual_provider"

class OutreachEngine
  def initialize(db)
    @db = db
    @policy = OutreachPolicy.new(db)
    @provider = ManualProvider.new(db)
  end

  def prepare_and_send(flow_id)
    flow = one("SELECT * FROM automation_flows WHERE id = ?", [flow_id])
    raise "Flow não encontrado" unless flow

    deal = one("SELECT * FROM deals WHERE id = ?", [flow["deal_id"]])
    raise "Deal não encontrado" unless deal

    task = one("SELECT * FROM tasks WHERE id = ?", [deal["task_id"]])
    raise "Task não encontrada" unless task

    contact = one("SELECT * FROM contacts WHERE id = ?", [deal["contact_id"]])
    raise "Contato não encontrado" unless contact

    existing = one(
      <<~SQL,
        SELECT *
        FROM outreach_messages
        WHERE flow_id = ?
          AND deal_id = ?
          AND status IN ('draft', 'policy_approved', 'queued', 'sent', 'replied')
        ORDER BY id DESC
        LIMIT 1
      SQL
      [flow_id, deal["id"]]
    )

    return existing if existing && existing["status"] == "sent"

    policy_result = @policy.allowed?(
      task: task,
      deal: deal,
      contact: contact,
      channel: "manual_provider"
    )

    built = OutreachBuilder.build(
      task: task,
      deal: deal,
      contact: contact
    )

    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        INSERT INTO outreach_messages
        (
          flow_id,
          deal_id,
          task_id,
          contact_id,
          channel,
          provider,
          status,
          risk_level,
          policy_status,
          policy_reason,
          subject,
          message_body,
          created_at,
          updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        flow_id,
        deal["id"],
        task["id"],
        contact["id"],
        "manual_provider",
        "manual_provider",
        policy_result[:allowed] ? "policy_approved" : "blocked",
        policy_result[:risk_level],
        policy_result[:allowed] ? "approved" : "denied",
        policy_result[:reason],
        built[:subject],
        built[:message_body],
        now,
        now
      ]
    )

    message_id = @db.last_insert_row_id
    message = one("SELECT * FROM outreach_messages WHERE id = ?", [message_id])

    create_outreach_event(
      message_id,
      flow_id,
      deal["id"],
      policy_result[:allowed] ? "policy_approved" : "policy_blocked",
      policy_result[:allowed] ? "Política aprovada" : "Política bloqueou envio",
      "reason=#{policy_result[:reason]}"
    )

    if policy_result[:allowed]
      result = @provider.send_message(message)

      create_outreach_event(
        message_id,
        flow_id,
        deal["id"],
        "sent",
        "Mensagem marcada como enviada",
        result[:note]
      )

      create_deal_event(deal["id"], "outreach_sent", "Abordagem enviada", "Mensagem ##{message_id} marcada como enviada via manual_provider.", "outreach_message_id=#{message_id}") if respond_to?(:create_deal_event)

      @db.execute(
        <<~SQL,
          UPDATE automation_flows
          SET current_state = 'outreach_sent',
              next_action = 'wait_interest',
              status = 'running',
              last_error = NULL,
              updated_at = ?
          WHERE id = ?
        SQL
        [Time.now.iso8601, flow_id]
      )
    else
      @db.execute(
        <<~SQL,
          UPDATE automation_flows
          SET status = 'blocked',
              last_error = ?,
              updated_at = ?
          WHERE id = ?
        SQL
        [policy_result[:reason], Time.now.iso8601, flow_id]
      )
    end

    one("SELECT * FROM outreach_messages WHERE id = ?", [message_id])
  end

  private

  def create_outreach_event(message_id, flow_id, deal_id, event_type, title, description = nil, metadata = nil)
    @db.execute(
      <<~SQL,
        INSERT INTO outreach_events
        (
          outreach_message_id,
          flow_id,
          deal_id,
          event_type,
          title,
          description,
          metadata,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [message_id, flow_id, deal_id, event_type, title, description, metadata, Time.now.iso8601]
    )
  end

  def one(sql, params = [])
    row = @db.get_first_row(sql, params)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
