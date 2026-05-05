require "time"

class ConciergeEngine
  def initialize(db)
    @db = db
  end

  def sync_all
    flows = all(
      <<~SQL
        SELECT *
        FROM automation_flows
        WHERE status IN ('running', 'blocked')
        ORDER BY id DESC
        LIMIT 100
      SQL
    )

    flows.each { |flow| sync_flow(flow["id"]) }
  end

  def sync_flow(flow_id)
    flow = one("SELECT * FROM automation_flows WHERE id = ?", [flow_id])
    return nil unless flow

    return nil if flow["status"] == "completed"
    return nil if flow["current_state"] == "completed"

    existing = one(
      <<~SQL,
        SELECT *
        FROM concierge_requests
        WHERE flow_id = ?
          AND status = 'pending'
        ORDER BY id DESC
        LIMIT 1
      SQL
      [flow_id]
    )

    return existing if existing

    request = build_request(flow)
    return nil unless request

    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        INSERT INTO concierge_requests
        (
          flow_id,
          task_id,
          deal_id,
          request_type,
          status,
          title,
          description,
          action_label,
          created_at,
          updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        flow["id"],
        flow["task_id"],
        flow["deal_id"],
        request[:request_type],
        "pending",
        request[:title],
        request[:description],
        request[:action_label],
        now,
        now
      ]
    )

    request_id = @db.last_insert_row_id

    create_event(
      request_id: request_id,
      flow_id: flow_id,
      event_type: "request_created",
      title: "Permissão criada",
      description: request[:title]
    )

    one("SELECT * FROM concierge_requests WHERE id = ?", [request_id])
  end

  def approve_request(request_id, response_status: nil)
    request = one("SELECT * FROM concierge_requests WHERE id = ?", [request_id])
    raise "Permissão não encontrada" unless request
    raise "Permissão não está pendente" unless request["status"] == "pending"

    flow = one("SELECT * FROM automation_flows WHERE id = ?", [request["flow_id"]])
    raise "Flow não encontrado" unless flow

    result = execute_request(request, flow, response_status: response_status)

    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        UPDATE concierge_requests
        SET status = 'approved',
            result_message = ?,
            updated_at = ?,
            resolved_at = ?
        WHERE id = ?
      SQL
      [result, now, now, request_id]
    )

    create_event(
      request_id: request_id,
      flow_id: request["flow_id"],
      event_type: "request_approved",
      title: "Permissão aprovada",
      description: result
    )

    sync_flow(request["flow_id"])

    result
  end

  def reject_request(request_id)
    request = one("SELECT * FROM concierge_requests WHERE id = ?", [request_id])
    raise "Permissão não encontrada" unless request

    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        UPDATE concierge_requests
        SET status = 'rejected',
            result_message = 'Permissão recusada pelo operador.',
            updated_at = ?,
            resolved_at = ?
        WHERE id = ?
      SQL
      [now, now, request_id]
    )

    create_event(
      request_id: request_id,
      flow_id: request["flow_id"],
      event_type: "request_rejected",
      title: "Permissão recusada",
      description: "Operador recusou a permissão."
    )
  end

  private

  def build_request(flow)
    state = flow["current_state"].to_s
    action = flow["next_action"].to_s
    status = flow["status"].to_s
    error = flow["last_error"].to_s

    if status == "blocked" && error == "missing_contact"
      return {
        request_type: "missing_contact",
        title: "Contato obrigatório",
        description: "Vincule um contato ao deal antes de continuar.",
        action_label: "Aguardando contato"
      }
    end

    if status == "blocked" && error == "waiting_outreach_approval"
      return {
        request_type: "approve_outreach",
        title: "Liberar abordagem controlada",
        description: "O fluxo está pronto para gerar/marcar outreach via manual_provider.",
        action_label: "Liberar outreach"
      }
    end

    if state == "contact_ready" && action == "prepare_outreach"
      return {
        request_type: "approve_outreach",
        title: "Liberar abordagem controlada",
        description: "Contato pronto. Autorize o Concierge a executar a abordagem controlada.",
        action_label: "Liberar outreach"
      }
    end

    if state == "outreach_sent" && action == "wait_interest"
      return {
        request_type: "register_response",
        title: "Registrar retorno do contato",
        description: "Informe se o contato demonstrou interesse, recusou ou pediu mais detalhes.",
        action_label: "Registrar resposta"
      }
    end

    if state == "interested" && action == "create_payment"
      return {
        request_type: "approve_payment_creation",
        title: "Criar cobrança",
        description: "Contato interessado. Autorize a criação da cobrança Pix/manual.",
        action_label: "Criar cobrança"
      }
    end

    if state == "payment_created" && action == "wait_payment"
      return {
        request_type: "confirm_payment",
        title: "Confirmar pagamento",
        description: "Cobrança criada. Confirme o pagamento real para concluir o fluxo.",
        action_label: "Confirmar pagamento"
      }
    end

    if status == "blocked" && error == "waiting_payment"
      return {
        request_type: "confirm_payment",
        title: "Confirmar pagamento",
        description: "O fluxo está aguardando confirmação de pagamento.",
        action_label: "Confirmar pagamento"
      }
    end

    if state == "payment_paid" && action == "complete_flow"
      return {
        request_type: "complete_flow",
        title: "Concluir fluxo",
        description: "Pagamento confirmado. Autorize a finalização do fluxo.",
        action_label: "Concluir"
      }
    end

    if status == "running" && !action.empty?
      return {
        request_type: "continue_internal",
        title: "Executar próxima etapa interna",
        description: "O fluxo possui uma etapa interna pendente: #{action}.",
        action_label: "Executar próxima etapa"
      }
    end

    nil
  end

  def execute_request(request, flow, response_status: nil)
    type = request["request_type"]

    case type
    when "continue_internal"
      AutomationEngine.new(@db).run_next(flow["id"])
      "Etapa interna executada."

    when "approve_outreach"
      resume_flow(flow["id"])
      AutomationEngine.new(@db).run_next(flow["id"])
      "Outreach liberado e executado via fluxo sequencial."

    when "register_response"
      status = response_status.to_s.strip
      status = "interested" if status.empty?

      message = one(
        "SELECT * FROM outreach_messages WHERE flow_id = ? ORDER BY id DESC LIMIT 1",
        [flow["id"]]
      )

      raise "Nenhuma mensagem de outreach encontrada" unless message

      register_response(message, status)
      "Resposta registrada como #{status}."

    when "approve_payment_creation"
      resume_flow(flow["id"])
      AutomationEngine.new(@db).run_next(flow["id"])
      "Cobrança criada ou validada pelo fluxo."

    when "confirm_payment"
      payment = one(
        "SELECT * FROM payments WHERE deal_id = ? AND status = 'pending' ORDER BY id DESC LIMIT 1",
        [flow["deal_id"]]
      )

      if payment
        mark_payment_paid(payment)
      end

      resume_flow(flow["id"])
      AutomationEngine.new(@db).run_next(flow["id"])

      updated = one("SELECT * FROM automation_flows WHERE id = ?", [flow["id"]])

      if updated && updated["next_action"] == "complete_flow"
        AutomationEngine.new(@db).run_next(flow["id"])
      end

      "Pagamento confirmado e fluxo avançado."

    when "complete_flow"
      resume_flow(flow["id"])
      AutomationEngine.new(@db).run_next(flow["id"])
      "Fluxo concluído."

    when "missing_contact"
      "Ação manual necessária: vincule um contato ao deal."

    else
      raise "Tipo de permissão desconhecido: #{type}"
    end
  end

  def register_response(message, status)
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        UPDATE outreach_messages
        SET status = 'replied',
            response_status = ?,
            replied_at = ?,
            updated_at = ?
        WHERE id = ?
      SQL
      [status, now, now, message["id"]]
    )

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
      [
        message["id"],
        message["flow_id"],
        message["deal_id"],
        "replied",
        "Resposta registrada pelo Concierge",
        "Resposta marcada como #{status}.",
        "response_status=#{status}",
        now
      ]
    )

    if status == "interested"
      @db.execute("UPDATE deals SET status = 'interessado', updated_at = ? WHERE id = ?", [now, message["deal_id"]])
      @db.execute(
        "UPDATE automation_flows SET current_state = 'interested', next_action = 'create_payment', status = 'running', last_error = NULL, updated_at = ? WHERE id = ?",
        [now, message["flow_id"]]
      )
    elsif status == "not_interested"
      @db.execute("UPDATE deals SET status = 'perdido', updated_at = ? WHERE id = ?", [now, message["deal_id"]])
      @db.execute(
        "UPDATE automation_flows SET current_state = 'lost', next_action = NULL, status = 'lost', last_error = NULL, updated_at = ?, completed_at = ? WHERE id = ?",
        [now, now, message["flow_id"]]
      )
    else
      @db.execute(
        "UPDATE automation_flows SET current_state = 'outreach_sent', next_action = 'wait_interest', status = 'blocked', last_error = 'needs_more_info', updated_at = ? WHERE id = ?",
        [now, message["flow_id"]]
      )
    end
  end

  def mark_payment_paid(payment)
    now = Time.now.iso8601

    @db.execute(
      "UPDATE payments SET status = 'paid', paid_at = ?, updated_at = ? WHERE id = ?",
      [now, now, payment["id"]]
    )

    @db.execute(
      "UPDATE tasks SET status = 'ok', stage = 'historico', paid_at = ?, updated_at = ? WHERE id = ?",
      [now, now, payment["task_id"]]
    )

    @db.execute(
      "UPDATE deals SET status = 'fechado', updated_at = ? WHERE id = ?",
      [now, payment["deal_id"]]
    )
  end

  def resume_flow(flow_id)
    @db.execute(
      "UPDATE automation_flows SET status = 'running', last_error = NULL, locked = 0, updated_at = ? WHERE id = ?",
      [Time.now.iso8601, flow_id]
    )
  end

  def create_event(request_id:, flow_id:, event_type:, title:, description:)
    @db.execute(
      <<~SQL,
        INSERT INTO concierge_events
        (
          request_id,
          flow_id,
          event_type,
          title,
          description,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?)
      SQL
      [request_id, flow_id, event_type, title, description, Time.now.iso8601]
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
