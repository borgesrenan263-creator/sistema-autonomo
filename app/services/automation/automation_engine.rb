require "time"

class AutomationEngine
  SAFE_FINAL_STATES = ["completed", "lost", "cancelled"]

  def initialize(db)
    @db = db
    @events = AutomationEventLogger.new(db)
  end

  def start_for_task(task_id)
    existing = get_one(
      <<~SQL,
        SELECT *
        FROM automation_flows
        WHERE task_id = ?
          AND status IN ('running', 'blocked')
        ORDER BY id DESC
        LIMIT 1
      SQL
      [task_id]
    )

    return existing if existing

    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        INSERT INTO automation_flows
        (
          task_id,
          current_state,
          next_action,
          status,
          locked,
          started_at,
          updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        task_id,
        "detected",
        "qualify_task",
        "running",
        0,
        now,
        now
      ]
    )

    flow_id = @db.last_insert_row_id

    @events.create(
      flow_id: flow_id,
      event_type: "automation_started",
      title: "Automação iniciada",
      description: "Fluxo sequencial iniciado para a task #{task_id}."
    )

    find_flow(flow_id)
  end

  def run_next(flow_id)
    flow = find_flow(flow_id)
    raise "Fluxo não encontrado" unless flow
    raise "Fluxo finalizado" if SAFE_FINAL_STATES.include?(flow["current_state"].to_s)
    raise "Fluxo bloqueado" if flow["status"] == "blocked"
    raise "Fluxo travado" if flow["locked"].to_i == 1

    lock(flow_id)

    begin
      case flow["next_action"]
      when "qualify_task"
        step_qualify_task(flow)
      when "generate_delivery"
        step_generate_delivery(flow)
      when "generate_proposal"
        step_generate_proposal(flow)
      when "check_contact"
        step_check_contact(flow)
      when "prepare_outreach"
        step_prepare_outreach(flow)
      when "wait_interest"
        block_flow(flow, "waiting_interest", "Aguardando interesse", "O fluxo está aguardando resposta/interesse antes de criar cobrança.")
      when "create_payment"
        step_create_payment(flow)
      when "wait_payment"
        step_wait_payment(flow)
      when "complete_flow"
        step_complete_flow(flow)
      else
        block_flow(flow, "unknown_next_action", "Próxima ação desconhecida", "A ação #{flow["next_action"]} não foi reconhecida.")
      end
    rescue => e
      fail_flow(flow_id, e.message)
    ensure
      unlock(flow_id)
    end

    find_flow(flow_id)
  end

  private

  def step_qualify_task(flow)
    task = get_one("SELECT * FROM tasks WHERE id = ?", [flow["task_id"]])
    raise "Task não encontrada" unless task

    if task["quality_status"] == "ignore"
      update_flow(flow["id"], "lost", nil, "lost", "Task ignorada pelo Quality Gate.")
      log_step(flow["id"], "qualify_task", "done", "quality_status=ignore")
      return
    end

    unless task["quality_status"] == "monetizable"
      block_flow(flow, "not_monetizable", "Task ainda não monetizável", "Quality atual: #{task["quality_status"]}.")
      return
    end

    log_step(flow["id"], "qualify_task", "done", "quality_status=monetizable")
    update_flow(flow["id"], "qualified", "generate_delivery", "running", nil)

    @events.create(
      flow_id: flow["id"],
      event_type: "state_changed",
      title: "Task qualificada",
      description: "Task aprovada como monetizable."
    )
  end

  def step_generate_delivery(flow)
    task = get_one("SELECT * FROM tasks WHERE id = ?", [flow["task_id"]])
    raise "Task não encontrada" unless task

    latest_delivery = get_one(
      "SELECT * FROM deliveries WHERE task_id = ? ORDER BY version DESC LIMIT 1",
      [flow["task_id"]]
    )

    if latest_delivery
      log_step(flow["id"], "generate_delivery", "skipped", "delivery_id=#{latest_delivery["id"]}")
      update_flow(flow["id"], "delivery_generated", "generate_proposal", "running", nil)
      return
    end

    delivery = DeliveryGenerator.generate(task)
    now = Time.now.iso8601

    version_row = get_one(
      "SELECT COALESCE(MAX(version), 0) AS version FROM deliveries WHERE task_id = ?",
      [flow["task_id"]]
    )

    next_version = version_row["version"].to_i + 1

    @db.execute(
      <<~SQL,
        INSERT INTO deliveries
        (
          task_id,
          version,
          category,
          content,
          status,
          created_at,
          updated_at,
          generator_type,
          provider,
          model,
          error_message
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        flow["task_id"],
        next_version,
        delivery[:category],
        delivery[:content],
        "ready",
        now,
        now,
        delivery[:generator_type],
        delivery[:provider],
        delivery[:model],
        delivery[:error_message]
      ]
    )

    delivery_id = @db.last_insert_row_id

    @db.execute(
      "UPDATE tasks SET status = 'faturamento', stage = 'faturamento', result = ?, executed_at = ?, updated_at = ? WHERE id = ?",
      [delivery[:content], now, now, flow["task_id"]]
    )

    log_step(flow["id"], "generate_delivery", "done", "delivery_id=#{delivery_id};provider=#{delivery[:provider]}")
    update_flow(flow["id"], "delivery_generated", "generate_proposal", "running", nil)

    @events.create(
      flow_id: flow["id"],
      event_type: "delivery_generated",
      title: "Entrega gerada",
      description: "Entrega ##{delivery_id} gerada com #{delivery[:provider]}."
    )
  end

  def step_generate_proposal(flow)
    task = get_one("SELECT * FROM tasks WHERE id = ?", [flow["task_id"]])
    raise "Task não encontrada" unless task

    open_deal = get_one(
      <<~SQL,
        SELECT *
        FROM deals
        WHERE task_id = ?
          AND status IN ('proposta_criada', 'abordado', 'interessado')
        ORDER BY id DESC
        LIMIT 1
      SQL
      [flow["task_id"]]
    )

    if open_deal
      @db.execute(
        "UPDATE automation_flows SET deal_id = ?, updated_at = ? WHERE id = ?",
        [open_deal["id"], Time.now.iso8601, flow["id"]]
      )

      log_step(flow["id"], "generate_proposal", "skipped", "existing_deal_id=#{open_deal["id"]}")
      update_flow(flow["id"], "proposal_generated", "check_contact", "running", nil)
      return
    end

    delivery = get_one(
      "SELECT * FROM deliveries WHERE task_id = ? ORDER BY version DESC LIMIT 1",
      [flow["task_id"]]
    )

    raise "Entrega não encontrada para gerar proposta" unless delivery

    proposal = CommercialProposalGenerator.generate(task, delivery)
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        INSERT INTO proposals
        (
          task_id,
          delivery_id,
          title,
          pain_summary,
          solution_scope,
          out_of_scope,
          price,
          estimated_timeline,
          approach_message,
          status,
          created_at,
          updated_at,
          generator_type,
          provider,
          model,
          error_message
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        task["id"],
        delivery["id"],
        proposal[:title],
        proposal[:pain_summary],
        proposal[:solution_scope],
        proposal[:out_of_scope],
        proposal[:price],
        proposal[:estimated_timeline],
        proposal[:approach_message],
        "draft",
        now,
        now,
        proposal[:generator_type],
        proposal[:provider],
        proposal[:model],
        proposal[:error_message]
      ]
    )

    proposal_id = @db.last_insert_row_id

    @db.execute(
      <<~SQL,
        INSERT INTO deals
        (
          task_id,
          proposal_id,
          status,
          value,
          next_action,
          notes,
          created_at,
          updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        task["id"],
        proposal_id,
        "proposta_criada",
        proposal[:price],
        "Vincular contato antes da abordagem externa.",
        "Deal criado automaticamente pelo Sequential Automation Engine.",
        now,
        now
      ]
    )

    deal_id = @db.last_insert_row_id

    @db.execute(
      "UPDATE automation_flows SET deal_id = ?, updated_at = ? WHERE id = ?",
      [deal_id, now, flow["id"]]
    )

    create_deal_event_if_available(
      deal_id,
      "proposal_created",
      "Proposta criada",
      "Proposta ##{proposal_id} criada pelo motor sequencial.",
      "provider=#{proposal[:provider]};model=#{proposal[:model]}"
    )

    log_step(flow["id"], "generate_proposal", "done", "proposal_id=#{proposal_id};deal_id=#{deal_id}")
    update_flow(flow["id"], "proposal_generated", "check_contact", "running", nil)

    @events.create(
      flow_id: flow["id"],
      event_type: "proposal_generated",
      title: "Proposta e deal criados",
      description: "Proposta ##{proposal_id} e Deal ##{deal_id} criados."
    )
  end

  def step_check_contact(flow)
    deal = resolve_deal(flow)
    raise "Deal não encontrado" unless deal

    if deal["contact_id"].to_s.strip.empty?
      block_flow(flow, "missing_contact", "Contato obrigatório", "Vincule um contato ao deal antes da abordagem.")
      return
    end

    log_step(flow["id"], "check_contact", "done", "contact_id=#{deal["contact_id"]}")
    update_flow(flow["id"], "contact_ready", "prepare_outreach", "running", nil)

    @events.create(
      flow_id: flow["id"],
      event_type: "contact_ready",
      title: "Contato pronto",
      description: "Deal possui contato vinculado."
    )
  end

  def step_prepare_outreach(flow)
    deal = resolve_deal(flow)
    raise "Deal não encontrado" unless deal

    unless defined?(OutreachEngine)
      block_flow(
        flow,
        "outreach_engine_missing",
        "Outreach Engine ausente",
        "O motor de outreach ainda não foi carregado."
      )
      return
    end

    message = OutreachEngine.new(@db).prepare_and_send(flow["id"])

    if message["status"] == "sent"
      log_step(flow["id"], "prepare_outreach", "done", "outreach_message_id=#{message["id"]};provider=#{message["provider"]}")

      @events.create(
        flow_id: flow["id"],
        event_type: "outreach_sent",
        title: "Abordagem enviada",
        description: "Mensagem ##{message["id"]} enviada/marcada como enviada pelo provider #{message["provider"]}."
      )
    else
      log_step(flow["id"], "prepare_outreach", "blocked", "outreach_message_id=#{message["id"]};reason=#{message["policy_reason"]}")

      block_flow(
        flow,
        message["policy_reason"],
        "Outreach bloqueado",
        "A política de outreach bloqueou esta abordagem."
      )
    end
  end


  def step_create_payment(flow)
    deal = resolve_deal(flow)
    raise "Deal não encontrado" unless deal

    existing = get_one("SELECT * FROM payments WHERE deal_id = ? AND status IN ('pending', 'paid') LIMIT 1", [deal["id"]])

    if existing
      log_step(flow["id"], "create_payment", "skipped", "payment_id=#{existing["id"]}")
      update_flow(flow["id"], "payment_created", "wait_payment", "running", nil)
      return
    end

    now = Time.now.iso8601

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
          created_at,
          updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        deal["id"],
        deal["task_id"],
        deal["value"],
        "pix_manual",
        "PIX configurado",
        "pending",
        "deal-#{deal["id"]}",
        now,
        now
      ]
    )

    payment_id = @db.last_insert_row_id

    create_deal_event_if_available(
      deal["id"],
      "payment_created",
      "Cobrança criada",
      "Cobrança Pix/manual ##{payment_id} criada pelo motor sequencial.",
      "payment_id=#{payment_id};amount=#{deal["value"]}"
    )

    log_step(flow["id"], "create_payment", "done", "payment_id=#{payment_id}")
    update_flow(flow["id"], "payment_created", "wait_payment", "running", nil)

    @events.create(
      flow_id: flow["id"],
      event_type: "payment_created",
      title: "Cobrança criada",
      description: "Cobrança ##{payment_id} criada."
    )
  end

  def step_wait_payment(flow)
    deal = resolve_deal(flow)
    raise "Deal não encontrado" unless deal

    payment = get_one(
      "SELECT * FROM payments WHERE deal_id = ? AND status = 'paid' ORDER BY id DESC LIMIT 1",
      [deal["id"]]
    )

    unless payment
      block_flow(flow, "waiting_payment", "Aguardando pagamento", "O fluxo está aguardando confirmação de pagamento.")
      return
    end

    log_step(flow["id"], "wait_payment", "done", "payment_id=#{payment["id"]};status=paid")
    update_flow(flow["id"], "payment_paid", "complete_flow", "running", nil)

    @events.create(
      flow_id: flow["id"],
      event_type: "payment_paid",
      title: "Pagamento confirmado",
      description: "Pagamento ##{payment["id"]} confirmado. Fluxo liberado para finalização."
    )
  end

  def step_complete_flow(flow)
    deal = resolve_deal(flow)
    raise "Deal não encontrado" unless deal

    payment = get_one("SELECT * FROM payments WHERE deal_id = ? AND status = 'paid' ORDER BY id DESC LIMIT 1", [deal["id"]])

    unless payment
      block_flow(flow, "payment_not_paid", "Pagamento não confirmado", "O pagamento ainda não está como paid.")
      return
    end

    now = Time.now.iso8601

    @db.execute(
      "UPDATE tasks SET status = 'ok', stage = 'historico', paid_at = ?, updated_at = ? WHERE id = ?",
      [payment["paid_at"] || now, now, deal["task_id"]]
    )

    update_flow(flow["id"], "completed", nil, "completed", nil, completed_at: now)
    log_step(flow["id"], "complete_flow", "done", "payment_id=#{payment["id"]}")

    @events.create(
      flow_id: flow["id"],
      event_type: "automation_completed",
      title: "Automação concluída",
      description: "Fluxo concluído com pagamento confirmado."
    )
  end

  def resolve_deal(flow)
    return get_one("SELECT * FROM deals WHERE id = ?", [flow["deal_id"]]) if flow["deal_id"]

    get_one(
      "SELECT * FROM deals WHERE task_id = ? ORDER BY id DESC LIMIT 1",
      [flow["task_id"]]
    )
  end

  def block_flow(flow, reason, title, description)
    update_flow(flow["id"], flow["current_state"], flow["next_action"], "blocked", reason)

    @events.create(
      flow_id: flow["id"],
      event_type: "step_blocked",
      title: title,
      description: description,
      metadata: "reason=#{reason}"
    )
  end

  def fail_flow(flow_id, message)
    @db.execute(
      "UPDATE automation_flows SET status = 'failed', last_error = ?, locked = 0, updated_at = ? WHERE id = ?",
      [message, Time.now.iso8601, flow_id]
    )

    @events.create(
      flow_id: flow_id,
      event_type: "step_failed",
      title: "Etapa falhou",
      description: message
    )
  end

  def update_flow(id, current_state, next_action, status, last_error, completed_at: nil)
    @db.execute(
      <<~SQL,
        UPDATE automation_flows
        SET current_state = ?,
            next_action = ?,
            status = ?,
            last_error = ?,
            completed_at = COALESCE(?, completed_at),
            updated_at = ?
        WHERE id = ?
      SQL
      [
        current_state,
        next_action,
        status,
        last_error,
        completed_at,
        Time.now.iso8601,
        id
      ]
    )
  end

  def log_step(flow_id, step_key, status, metadata = nil)
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        INSERT INTO automation_steps
        (
          flow_id,
          step_key,
          status,
          started_at,
          finished_at,
          metadata
        )
        VALUES (?, ?, ?, ?, ?, ?)
      SQL
      [
        flow_id,
        step_key,
        status,
        now,
        now,
        metadata
      ]
    )
  end

  def create_deal_event_if_available(deal_id, event_type, title, description, metadata = nil)
    if defined?(create_deal_event)
      create_deal_event(deal_id, event_type, title, description, metadata)
    else
      @db.execute(
        <<~SQL,
          INSERT INTO deal_events
          (deal_id, event_type, title, description, metadata, created_at)
          VALUES (?, ?, ?, ?, ?, ?)
        SQL
        [deal_id, event_type, title, description, metadata, Time.now.iso8601]
      )
    end
  rescue
    nil
  end

  def lock(flow_id)
    @db.execute("UPDATE automation_flows SET locked = 1, updated_at = ? WHERE id = ?", [Time.now.iso8601, flow_id])
  end

  def unlock(flow_id)
    @db.execute("UPDATE automation_flows SET locked = 0, updated_at = ? WHERE id = ?", [Time.now.iso8601, flow_id])
  end

  def find_flow(id)
    get_one("SELECT * FROM automation_flows WHERE id = ?", [id])
  end

  def get_one(sql, params = [])
    row = @db.get_first_row(sql, params)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
