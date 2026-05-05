require "time"

class ObservabilityEngine
  def initialize(db)
    @db = db
  end

  def scan
    scan_response_waiting
    scan_payment_waiting
    scan_validation_missing
  end

  private

  def scan_response_waiting
    flows = all(
      <<~SQL
        SELECT *
        FROM automation_flows
        WHERE current_state = 'outreach_sent'
          AND next_action = 'wait_interest'
          AND status IN ('running', 'blocked')
      SQL
    )

    flows.each do |flow|
      signal(
        signal_type: "response_waiting",
        entity_type: "automation_flow",
        entity_id: flow["id"],
        flow_id: flow["id"],
        deal_id: flow["deal_id"],
        task_id: flow["task_id"],
        severity: "info",
        title: "Aguardando resposta do contato",
        detail: "O Flow ##{flow["id"]} já teve outreach e aguarda retorno real do contato.",
        link: "/concierge"
      )
    end
  end

  def scan_payment_waiting
    flows = all(
      <<~SQL
        SELECT *
        FROM automation_flows
        WHERE current_state = 'payment_created'
          AND next_action = 'wait_payment'
          AND status IN ('running', 'blocked')
      SQL
    )

    flows.each do |flow|
      payment = one(
        "SELECT * FROM payments WHERE deal_id = ? ORDER BY id DESC LIMIT 1",
        [flow["deal_id"]]
      )

      next if payment && payment["status"] == "paid"

      signal(
        signal_type: "payment_waiting",
        entity_type: "automation_flow",
        entity_id: flow["id"],
        flow_id: flow["id"],
        deal_id: flow["deal_id"],
        task_id: flow["task_id"],
        severity: "warning",
        title: "Aguardando confirmação de pagamento",
        detail: "O Flow ##{flow["id"]} está na etapa de pagamento e aguarda confirmação real.",
        link: "/financeiro"
      )
    end
  end

  def scan_validation_missing
    deliveries = all(
      <<~SQL
        SELECT deliveries.*, tasks.title AS task_title
        FROM deliveries
        INNER JOIN tasks ON tasks.id = deliveries.task_id
        WHERE deliveries.status IS NULL
           OR deliveries.status != 'validated'
        ORDER BY deliveries.id DESC
        LIMIT 50
      SQL
    )

    deliveries.each do |delivery|
      signal(
        signal_type: "validation_missing",
        entity_type: "delivery",
        entity_id: delivery["id"],
        flow_id: nil,
        deal_id: nil,
        task_id: delivery["task_id"],
        severity: "info",
        title: "Validação técnica externa pendente",
        detail: "A entrega ##{delivery["id"]} da task #{delivery["task_id"]} ainda não tem validação externa real.",
        link: "/deliveries/#{delivery["id"]}"
      )
    end
  end

  def signal(signal_type:, entity_type:, entity_id:, flow_id:, deal_id:, task_id:, severity:, title:, detail:, link:)
    existing = one(
      <<~SQL,
        SELECT *
        FROM observability_signals
        WHERE signal_type = ?
          AND entity_type = ?
          AND entity_id = ?
          AND status = 'open'
        LIMIT 1
      SQL
      [signal_type, entity_type, entity_id]
    )

    return existing if existing

    @db.execute(
      <<~SQL,
        INSERT INTO observability_signals
        (
          signal_type,
          entity_type,
          entity_id,
          flow_id,
          deal_id,
          task_id,
          severity,
          status,
          title,
          detail,
          link,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        signal_type,
        entity_type,
        entity_id,
        flow_id,
        deal_id,
        task_id,
        severity,
        "open",
        title,
        detail,
        link,
        Time.now.iso8601
      ]
    )
  end

  def one(sql, params = [])
    row = @db.get_first_row(sql, params)
    row&.reject { |k, _| k.is_a?(Integer) }
  end

  def all(sql, params = [])
    @db.execute(sql, params).map { |row| row.reject { |k, _| k.is_a?(Integer) } }
  end
end
