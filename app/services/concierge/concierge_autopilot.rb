require "time"

class ConciergeAutopilot
  AUTO_APPROVE_TYPES = [
    "continue_internal",
    "approve_outreach",
    "approve_payment_creation",
    "complete_flow"
  ]

  def initialize(db)
    @db = db
    @concierge = ConciergeEngine.new(db)
    @notifier = SystemNotifier.new(db)
  end

  def run_once
    @concierge.sync_all

    pending = all(
      <<~SQL
        SELECT *
        FROM concierge_requests
        WHERE status = 'pending'
        ORDER BY id ASC
        LIMIT 50
      SQL
    )

    pending.each do |request|
      process_request(request)
    end

    notify_completed_flows

    true
  end

  private

  def process_request(request)
    type = request["request_type"].to_s

    if AUTO_APPROVE_TYPES.include?(type)
      @concierge.approve_request(request["id"])
      return
    end

    case type
    when "confirm_payment"
      process_payment_permission(request)
    when "register_response"
      notify_response_needed(request)
    when "missing_contact"
      notify_contact_needed(request)
    else
      notify_attention_needed(request)
    end
  rescue => e
    @notifier.notify(
      kind: "autopilot_error",
      title: "Erro no Concierge Autopilot",
      body: "#{e.class}: #{e.message}",
      link: "/concierge",
      dedupe_key: "autopilot_error_#{request["id"]}"
    )
  end

  def process_payment_permission(request)
    flow = one("SELECT * FROM automation_flows WHERE id = ?", [request["flow_id"]])
    return unless flow

    paid = one(
      "SELECT * FROM payments WHERE deal_id = ? AND status = 'paid' ORDER BY id DESC LIMIT 1",
      [flow["deal_id"]]
    )

    if paid
      @concierge.approve_request(request["id"])

      @notifier.notify(
        kind: "payment_completed",
        title: "Pagamento concluído",
        body: "O pagamento do Deal ##{flow["deal_id"]} foi confirmado e o fluxo avançou.",
        link: "/automations/#{flow["id"]}",
        dedupe_key: "payment_completed_flow_#{flow["id"]}"
      )
    else
      payment = one(
        "SELECT * FROM payments WHERE deal_id = ? ORDER BY id DESC LIMIT 1",
        [flow["deal_id"]]
      )

      amount = payment ? payment["amount"] : nil

      @notifier.notify(
        kind: "payment_waiting",
        title: "Task concluída aguardando pagamento",
        body: "O Flow ##{flow["id"]} chegou na cobrança#{amount ? " de R$ #{amount}" : ""} e está aguardando confirmação real de pagamento.",
        link: "/financeiro",
        dedupe_key: "payment_waiting_flow_#{flow["id"]}"
      )
    end
  end

  def notify_response_needed(request)
    @notifier.notify(
      kind: "response_waiting",
      title: "Aguardando retorno do contato",
      body: "O Flow ##{request["flow_id"]} já teve outreach registrado e aguarda retorno do contato.",
      link: "/concierge",
      dedupe_key: "response_waiting_flow_#{request["flow_id"]}"
    )
  end

  def notify_contact_needed(request)
    @notifier.notify(
      kind: "contact_needed",
      title: "Contato necessário",
      body: "O Flow ##{request["flow_id"]} precisa de contato vinculado antes de continuar.",
      link: request["deal_id"] ? "/deals/#{request["deal_id"]}" : "/concierge",
      dedupe_key: "contact_needed_flow_#{request["flow_id"]}"
    )
  end

  def notify_attention_needed(request)
    @notifier.notify(
      kind: "concierge_attention",
      title: "Concierge precisa de atenção",
      body: "Existe uma permissão pendente: #{request["title"]}.",
      link: "/concierge",
      dedupe_key: "concierge_attention_#{request["id"]}"
    )
  end

  def notify_completed_flows
    completed = all(
      <<~SQL
        SELECT *
        FROM automation_flows
        WHERE status = 'completed'
          AND completed_at IS NOT NULL
        ORDER BY completed_at DESC
        LIMIT 10
      SQL
    )

    completed.each do |flow|
      @notifier.notify(
        kind: "flow_completed",
        title: "Fluxo concluído",
        body: "O Flow ##{flow["id"]} foi concluído com sucesso.",
        link: "/automations/#{flow["id"]}",
        dedupe_key: "flow_completed_#{flow["id"]}"
      )
    end
  end

  def one(sql, params = [])
    row = @db.get_first_row(sql, params)
    row&.reject { |k, _| k.is_a?(Integer) }
  end

  def all(sql, params = [])
    @db.execute(sql, params).map { |row| row.reject { |k, _| k.is_a?(Integer) } }
  end
end
