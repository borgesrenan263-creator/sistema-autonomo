require "time"
require "json"

class FollowupAutopilotEngine
  SAFE_START = "08:00"
  SAFE_END = "22:00"

  def initialize(db)
    @db = db
  end

  def dashboard
    {
      generated_at: Time.now.iso8601,
      counts: counts,
      money_at_risk: money_at_risk,
      pending_followups: pending_followups,
      latest_followups: latest_followups,
      latest_events: latest_events,
      candidates: {
        proposal_deals: proposal_deal_candidates,
        pending_payments: pending_payment_candidates,
        interested_responses: interested_response_candidates,
        release_deliveries: release_delivery_candidates
      }
    }
  end

  def scan
    created = []

    proposal_deal_candidates.each do |deal|
      created << create_followup_for_deal(deal)
    end

    pending_payment_candidates.each do |payment|
      created << create_followup_for_payment(payment)
    end

    interested_response_candidates.each do |event|
      created << create_followup_for_response(event)
    end

    release_delivery_candidates.each do |delivery|
      created << create_followup_for_delivery(delivery)
    end

    created.compact
  end

  def run_due(limit = 20)
    due_followups.first(limit).map do |task|
      process_followup(task["id"])
    rescue => e
      mark_failed(task, "#{e.class}: #{e.message}")
    end
  end

  def process_followup(id)
    task = one("SELECT * FROM followup_tasks WHERE id = ?", [id])
    raise "Follow-up não encontrado" unless task

    return task unless ["pending", "queued"].include?(task["status"].to_s)

    unless inside_send_window?
      update_followup(task["id"], status: "queued", last_error: "Fora da janela segura de envio")
      record_event(task, "queued", "Follow-up aguardando janela", "Fora da janela segura de envio.")
      return one("SELECT * FROM followup_tasks WHERE id = ?", [task["id"]])
    end

    case task["followup_type"].to_s
    when "payment_recovery"
      execute_payment_recovery(task)
    when "proposal_followup"
      execute_proposal_followup(task)
    when "response_followup"
      execute_response_followup(task)
    when "delivery_release_followup"
      execute_delivery_release_followup(task)
    else
      update_followup(task["id"], status: "skipped", last_error: "Tipo sem executor")
      record_event(task, "skipped", "Tipo ignorado", "Follow-up type sem executor ativo.")
    end

    one("SELECT * FROM followup_tasks WHERE id = ?", [task["id"]])
  end

  def mark_done(id)
    task = one("SELECT * FROM followup_tasks WHERE id = ?", [id])
    raise "Follow-up não encontrado" unless task

    update_followup(id, status: "done")
    record_event(task, "done", "Follow-up concluído", "Marcado manualmente como concluído.")
  end

  def mark_lost(id)
    task = one("SELECT * FROM followup_tasks WHERE id = ?", [id])
    raise "Follow-up não encontrado" unless task

    update_followup(id, status: "lost")
    record_event(task, "lost", "Follow-up perdido", "Marcado como perdido.")
  end

  private

  def create_followup_for_deal(deal)
    return nil if followup_exists?("deal", deal["id"], "proposal_followup")

    message = <<~TXT.strip
      Olá, tudo bem?

      Passando para confirmar se faz sentido seguir com a proposta sobre:
      #{deal_title(deal)}

      Valor previsto: R$ #{format_money(deal["value"].to_f)}

      Posso te enviar os próximos passos?
    TXT

    create_followup(
      entity_type: "deal",
      entity_id: deal["id"],
      followup_type: "proposal_followup",
      priority: 70,
      due_at: Time.now.iso8601,
      message: message
    )
  end

  def create_followup_for_payment(payment)
    return nil if followup_exists?("payment", payment["id"], "payment_recovery")

    message = <<~TXT.strip
      Oi, tudo bem?

      A cobrança referente a #{payment["reference"] || "sua proposta"} ainda está pendente.

      Valor: R$ #{format_money(payment["amount"].to_f)}

      Posso reenviar os dados do Pix para facilitar?
    TXT

    create_followup(
      entity_type: "payment",
      entity_id: payment["id"],
      followup_type: "payment_recovery",
      priority: 90,
      due_at: Time.now.iso8601,
      message: message
    )
  end

  def create_followup_for_response(event)
    return nil if followup_exists?("response", event["id"], "response_followup")

    message = <<~TXT.strip
      Oi, obrigado pelo retorno.

      Vi seu interesse e posso seguir com os próximos passos agora.

      Quer que eu gere a cobrança e a entrega objetiva?
    TXT

    create_followup(
      entity_type: "response",
      entity_id: event["id"],
      followup_type: "response_followup",
      priority: 85,
      due_at: Time.now.iso8601,
      message: message
    )
  end

  def create_followup_for_delivery(delivery)
    return nil if followup_exists?("delivery", delivery["id"], "delivery_release_followup")

    message = "Entrega ##{delivery["id"]} está pronta para liberação. Validar canal de entrega e registrar conclusão."

    create_followup(
      entity_type: "delivery",
      entity_id: delivery["id"],
      followup_type: "delivery_release_followup",
      priority: 80,
      due_at: Time.now.iso8601,
      message: message
    )
  end

  def execute_payment_recovery(task)
    payment = one("SELECT * FROM payments WHERE id = ?", [task["entity_id"]])
    return complete_as_skipped(task, "Payment não encontrado") unless payment

    if payment["status"].to_s == "paid"
      update_followup(task["id"], status: "done")
      record_event(task, "done", "Pagamento já confirmado", "Payment ##{payment["id"]} já está pago.")
      return
    end

    create_outreach_from_followup(task, "Follow-up de pagamento pendente")

    if table_has_column?("payments", "followup_status")
      @db.execute(
        "UPDATE payments SET followup_status = ?, last_followup_at = ? WHERE id = ?",
        ["recovery_sent", Time.now.iso8601, payment["id"]]
      )
    end

    increment_attempt(task, "sent", "Follow-up de pagamento enfileirado.")
  end

  def execute_proposal_followup(task)
    deal = one("SELECT * FROM deals WHERE id = ?", [task["entity_id"]])
    return complete_as_skipped(task, "Deal não encontrado") unless deal

    if ["fechado", "paid", "perdido"].include?(deal["status"].to_s)
      update_followup(task["id"], status: "done")
      record_event(task, "done", "Deal já finalizado", "Deal ##{deal["id"]} status=#{deal["status"]}.")
      return
    end

    create_outreach_from_followup(task, "Follow-up de proposta")

    if table_has_column?("deals", "followup_status")
      @db.execute(
        "UPDATE deals SET followup_status = ?, last_followup_at = ?, next_action = ? WHERE id = ?",
        ["proposal_followup_sent", Time.now.iso8601, "Aguardando resposta do follow-up automático.", deal["id"]]
      )
    end

    increment_attempt(task, "sent", "Follow-up de proposta enfileirado.")
  end

  def execute_response_followup(task)
    event = one("SELECT * FROM response_inbox_events WHERE id = ?", [task["entity_id"]])
    return complete_as_skipped(task, "Response event não encontrado") unless event

    if event["action_status"].to_s != "" && !event["action_status"].nil?
      update_followup(task["id"], status: "done")
      record_event(task, "done", "Resposta já tratada", "Response ##{event["id"]} action_status=#{event["action_status"]}.")
      return
    end

    create_outreach_from_followup(task, "Follow-up de resposta interessada")
    increment_attempt(task, "sent", "Follow-up de resposta enfileirado.")
  end

  def execute_delivery_release_followup(task)
    delivery = one("SELECT * FROM deliveries WHERE id = ?", [task["entity_id"]])
    return complete_as_skipped(task, "Delivery não encontrada") unless delivery

    if table_has_column?("deliveries", "release_status")
      @db.execute(
        "UPDATE deliveries SET release_status = ?, release_note = ?, released_at = ? WHERE id = ?",
        ["release_followup_sent", "Follow-up de liberação registrado pelo autopilot.", Time.now.iso8601, delivery["id"]]
      )
    end

    update_followup(task["id"], status: "done")
    record_event(task, "done", "Liberação acompanhada", "Delivery ##{delivery["id"]} acompanhada pelo autopilot.")
  end

  def create_outreach_from_followup(task, subject_prefix)
    return false unless table_exists?("outreach_messages")

    body_column = first_existing_column("outreach_messages", ["body", "message", "content", "text", "message_body"])
    subject_column = table_has_column?("outreach_messages", "subject") ? "subject" : nil

    columns = []
    values = []

    {
      "flow_id" => nil,
      "deal_id" => related_deal_id(task),
      "contact_id" => related_contact_id(task),
      "status" => "queued",
      "policy_status" => "approved",
      "created_at" => Time.now.iso8601,
      "updated_at" => Time.now.iso8601
    }.each do |col, val|
      if table_has_column?("outreach_messages", col)
        columns << col
        values << val
      end
    end

    if subject_column
      columns << subject_column
      values << subject_prefix
    end

    if body_column
      columns << body_column
      values << task["message"].to_s
    end

    return false if columns.empty?

    placeholders = (["?"] * columns.length).join(", ")
    @db.execute("INSERT INTO outreach_messages (#{columns.join(", ")}) VALUES (#{placeholders})", values)
    true
  end

  def increment_attempt(task, status, detail)
    attempts = task["attempts"].to_i + 1
    next_status = attempts >= task["max_attempts"].to_i ? "done" : status

    @db.execute(
      "UPDATE followup_tasks SET status = ?, attempts = ?, updated_at = ? WHERE id = ?",
      [next_status, attempts, Time.now.iso8601, task["id"]]
    )

    record_event(task, next_status, "Follow-up processado", detail)
  end

  def complete_as_skipped(task, detail)
    update_followup(task["id"], status: "skipped", last_error: detail)
    record_event(task, "skipped", "Follow-up ignorado", detail)
  end

  def create_followup(entity_type:, entity_id:, followup_type:, priority:, due_at:, message:)
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        INSERT INTO followup_tasks
        (
          entity_type,
          entity_id,
          followup_type,
          status,
          priority,
          due_at,
          attempts,
          max_attempts,
          message,
          created_at,
          updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        entity_type,
        entity_id,
        followup_type,
        "pending",
        priority,
        due_at,
        0,
        3,
        message,
        now,
        now
      ]
    )

    followup = one("SELECT * FROM followup_tasks WHERE id = ?", [@db.last_insert_row_id])
    record_event(followup, "created", "Follow-up criado", "#{followup_type} para #{entity_type}##{entity_id}")
    followup
  end

  def proposal_deal_candidates
    return [] unless table_exists?("deals")

    all(
      <<~SQL
        SELECT *
        FROM deals
        WHERE status IN ('proposta_criada', 'interessado')
        ORDER BY id DESC
        LIMIT 50
      SQL
    )
  end

  def pending_payment_candidates
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

  def interested_response_candidates
    return [] unless table_exists?("response_inbox_events")

    all(
      <<~SQL
        SELECT *
        FROM response_inbox_events
        WHERE response_status = 'interested'
          AND (action_status IS NULL OR action_status = '')
        ORDER BY id DESC
        LIMIT 50
      SQL
    )
  rescue
    []
  end

  def release_delivery_candidates
    return [] unless table_exists?("deliveries")

    if table_has_column?("deliveries", "release_status")
      all(
        <<~SQL
          SELECT *
          FROM deliveries
          WHERE release_status = 'ready_to_release'
          ORDER BY id DESC
          LIMIT 50
        SQL
      )
    else
      []
    end
  end

  def pending_followups
    all(
      <<~SQL
        SELECT *
        FROM followup_tasks
        WHERE status IN ('pending', 'queued', 'sent')
        ORDER BY priority DESC, due_at ASC, id DESC
        LIMIT 100
      SQL
    )
  rescue
    []
  end

  def due_followups
    now = Time.now.iso8601

    all(
      <<~SQL,
        SELECT *
        FROM followup_tasks
        WHERE status IN ('pending', 'queued')
          AND (due_at IS NULL OR due_at <= ?)
        ORDER BY priority DESC, due_at ASC, id ASC
        LIMIT 100
      SQL
      [now]
    )
  rescue
    []
  end

  def latest_followups
    all("SELECT * FROM followup_tasks ORDER BY id DESC LIMIT 100")
  rescue
    []
  end

  def latest_events
    all("SELECT * FROM followup_events ORDER BY id DESC LIMIT 100")
  rescue
    []
  end

  def counts
    {
      total: scalar("SELECT COUNT(*) FROM followup_tasks"),
      pending: scalar("SELECT COUNT(*) FROM followup_tasks WHERE status = 'pending'"),
      queued: scalar("SELECT COUNT(*) FROM followup_tasks WHERE status = 'queued'"),
      sent: scalar("SELECT COUNT(*) FROM followup_tasks WHERE status = 'sent'"),
      done: scalar("SELECT COUNT(*) FROM followup_tasks WHERE status = 'done'"),
      failed: scalar("SELECT COUNT(*) FROM followup_tasks WHERE status = 'failed'"),
      lost: scalar("SELECT COUNT(*) FROM followup_tasks WHERE status = 'lost'")
    }
  rescue
    {}
  end

  def money_at_risk
    pending = scalar_float("SELECT COALESCE(SUM(amount), 0) FROM payments WHERE status = 'pending'")
    proposal = scalar_float("SELECT COALESCE(SUM(value), 0) FROM deals WHERE status IN ('proposta_criada', 'interessado')")
    {
      pending_payments: pending,
      proposal_pipeline: proposal,
      total: pending + proposal
    }
  rescue
    { pending_payments: 0, proposal_pipeline: 0, total: 0 }
  end

  def followup_exists?(entity_type, entity_id, followup_type)
    !!one(
      <<~SQL,
        SELECT *
        FROM followup_tasks
        WHERE entity_type = ?
          AND entity_id = ?
          AND followup_type = ?
          AND status IN ('pending', 'queued', 'sent')
        LIMIT 1
      SQL
      [entity_type, entity_id, followup_type]
    )
  end

  def update_followup(id, status: nil, last_error: nil)
    fields = []
    values = []

    if status
      fields << "status = ?"
      values << status
    end

    unless last_error.nil?
      fields << "last_error = ?"
      values << last_error
    end

    fields << "updated_at = ?"
    values << Time.now.iso8601
    values << id

    @db.execute("UPDATE followup_tasks SET #{fields.join(", ")} WHERE id = ?", values)
  end

  def record_event(task, event_type, title, detail)
    @db.execute(
      <<~SQL,
        INSERT INTO followup_events
        (
          followup_task_id,
          entity_type,
          entity_id,
          event_type,
          title,
          detail,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        task["id"],
        task["entity_type"],
        task["entity_id"],
        event_type,
        title,
        detail,
        Time.now.iso8601
      ]
    )
  end

  def related_deal_id(task)
    case task["entity_type"].to_s
    when "deal"
      task["entity_id"]
    when "payment"
      payment = one("SELECT * FROM payments WHERE id = ?", [task["entity_id"]])
      payment && payment["deal_id"]
    when "response"
      event = one("SELECT * FROM response_inbox_events WHERE id = ?", [task["entity_id"]])
      event && event["deal_id"]
    else
      nil
    end
  end

  def related_contact_id(task)
    deal_id = related_deal_id(task)
    return nil unless deal_id

    deal = one("SELECT * FROM deals WHERE id = ?", [deal_id])
    deal && deal["contact_id"]
  end

  def deal_title(deal)
    task = deal["task_id"] ? one("SELECT * FROM tasks WHERE id = ?", [deal["task_id"]]) : nil
    task ? task["title"] : "Deal ##{deal["id"]}"
  end

  def inside_send_window?
    now = Time.now
    current = now.strftime("%H:%M")
    current >= ENV.fetch("FOLLOWUP_WINDOW_START", SAFE_START) &&
      current <= ENV.fetch("FOLLOWUP_WINDOW_END", SAFE_END)
  end

  def first_existing_column(table, columns)
    columns.find { |column| table_has_column?(table, column) }
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

  def scalar_float(sql, params = [])
    row = @db.get_first_row(sql, params)
    return row.values.first.to_f if row.is_a?(Hash)
    row.to_a.first.to_f
  rescue
    0.0
  end

  def one(sql, params = [])
    row = @db.get_first_row(sql, params)
    row&.reject { |k, _| k.is_a?(Integer) }
  end

  def all(sql, params = [])
    @db.execute(sql, params).map { |row| row.reject { |k, _| k.is_a?(Integer) } }
  end

  def format_money(value)
    "%.2f" % value.to_f
  end
end
