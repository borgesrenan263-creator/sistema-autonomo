require "time"

class ResponseActionEngine
  def initialize(db)
    @db = db
  end

  def dashboard(filter: "open")
    events = response_events(filter)

    {
      generated_at: Time.now.iso8601,
      filter: filter,
      counts: counts,
      events: events.map { |event| enrich_event(event) }
    }
  end

  def mark_resolved(event_id, note: nil)
    event = find_event(event_id)
    raise "Response event não encontrado" unless event

    update_event_action(event_id, "resolved", note || "Resolvido pelo operador.")
    record_action(event, "resolved", note || "Resposta marcada como resolvida.")

    notify("response_resolved", "Resposta resolvida", "Response ##{event_id} foi marcada como resolvida.", "/responses/action-center")

    true
  end

  def ignore(event_id, note: nil)
    event = find_event(event_id)
    raise "Response event não encontrado" unless event

    update_event_action(event_id, "ignored", note || "Ignorado pelo operador.")
    record_action(event, "ignored", note || "Resposta ignorada.")

    true
  end

  def mark_interested(event_id)
    event = find_event(event_id)
    raise "Response event não encontrado" unless event

    deal_id = event["deal_id"]

    if deal_id
      @db.execute(
        "UPDATE deals SET status = ?, updated_at = ? WHERE id = ?",
        ["interessado", Time.now.iso8601, deal_id]
      )
    end

    update_event_action(event_id, "interested_confirmed", "Deal marcado como interessado.")
    record_action(event, "interested_confirmed", "Deal marcado como interessado.")

    true
  end

  def create_manual_charge(event_id)
    event = find_event(event_id)
    raise "Response event não encontrado" unless event

    deal = event["deal_id"] ? one("SELECT * FROM deals WHERE id = ?", [event["deal_id"]]) : nil
    raise "Deal não encontrado para cobrança" unless deal

    paid = one(
      "SELECT * FROM payments WHERE deal_id = ? AND status = 'paid' ORDER BY id DESC LIMIT 1",
      [deal["id"]]
    )

    if paid
      update_event_action(event_id, "already_paid", "Deal ##{deal["id"]} já possui pagamento confirmado.")
      record_action(event, "already_paid", "Cobrança não criada porque já existe payment paid ##{paid["id"]}.")

      notify(
        "payment_already_paid",
        "Deal já pago",
        "Deal ##{deal["id"]} já possui pagamento confirmado. Nenhuma cobrança nova foi criada.",
        "/finance/metrics"
      )

      return paid
    end

    existing = one(
      "SELECT * FROM payments WHERE deal_id = ? AND status = 'pending' ORDER BY id DESC LIMIT 1",
      [deal["id"]]
    )

    if existing
      payment = existing
    else
      now = Time.now.iso8601
      amount = money(deal["value"] || deal["amount"] || 0)
      amount = 720 if amount <= 0

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
            created_at,
            updated_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [
          deal["id"],
          deal["task_id"],
          amount,
          "pix_manual",
          "PIX configurado",
          "pending",
          "deal-#{deal["id"]}",
          "pix_manual",
          now,
          now
        ]
      )

      payment = one("SELECT * FROM payments WHERE id = ?", [@db.last_insert_row_id])
    end

    update_event_action(event_id, "charge_created", "Cobrança criada/identificada para deal ##{deal["id"]}.")
    record_action(event, "charge_created", "Cobrança pending criada/identificada. Payment ##{payment["id"]}.")

    notify(
      "payment_waiting",
      "Cobrança criada",
      "Cobrança do deal ##{deal["id"]} está aguardando pagamento.",
      "/finance/metrics"
    )

    payment
  end

  def suggested_message(event_id)
    event = find_event(event_id)
    enriched = enrich_event(event)

    deal = enriched[:deal]
    task = enriched[:task]
    contact = enriched[:contact]

    name = contact && (contact["name"] || contact["email"] || contact["handle"])
    title = task && task["title"]
    amount = deal && money(deal["value"] || 0)

    <<~TXT.strip
      Oi#{name ? " #{name}" : ""}, perfeito — obrigado pelo retorno.

      Posso seguir com os próximos passos para "#{title || "essa demanda"}".

      A proposta fica em R$ #{format_money(amount && amount > 0 ? amount : 720)} via Pix. Assim que o pagamento for confirmado, eu concluo a entrega e te envio o material/diagnóstico final.

      Posso te mandar a cobrança agora?
    TXT
  end

  private

  def response_events(filter)
    where =
      case filter.to_s
      when "interested"
        "response_status = 'interested'"
      when "invalid"
        "signature_valid = 0 OR processing_error IS NOT NULL"
      when "unprocessed"
        "processed IS NULL OR processed = 0"
      when "resolved"
        "action_status = 'resolved'"
      when "ignored"
        "action_status = 'ignored'"
      else
        "(action_status IS NULL OR action_status = '')"
      end

    all(
      <<~SQL
        SELECT *
        FROM response_inbox_events
        WHERE #{where}
        ORDER BY id DESC
        LIMIT 100
      SQL
    )
  rescue
    []
  end

  def counts
    {
      open: scalar("SELECT COUNT(*) FROM response_inbox_events WHERE action_status IS NULL OR action_status = ''"),
      interested: scalar("SELECT COUNT(*) FROM response_inbox_events WHERE response_status = 'interested'"),
      invalid: scalar("SELECT COUNT(*) FROM response_inbox_events WHERE signature_valid = 0 OR processing_error IS NOT NULL"),
      unprocessed: scalar("SELECT COUNT(*) FROM response_inbox_events WHERE processed IS NULL OR processed = 0"),
      resolved: scalar("SELECT COUNT(*) FROM response_inbox_events WHERE action_status = 'resolved'"),
      ignored: scalar("SELECT COUNT(*) FROM response_inbox_events WHERE action_status = 'ignored'")
    }
  rescue
    {}
  end

  def enrich_event(event)
    deal = event["deal_id"] ? one("SELECT * FROM deals WHERE id = ?", [event["deal_id"]]) : nil
    task = event["task_id"] ? one("SELECT * FROM tasks WHERE id = ?", [event["task_id"]]) : nil
    contact = event["contact_id"] ? one("SELECT * FROM contacts WHERE id = ?", [event["contact_id"]]) : nil
    payment = deal ? one("SELECT * FROM payments WHERE deal_id = ? ORDER BY id DESC LIMIT 1", [deal["id"]]) : nil

    {
      event: event,
      deal: deal,
      task: task,
      contact: contact,
      payment: payment,
      suggested_message: build_suggested_message(event, deal, task, contact)
    }
  end

  def build_suggested_message(event, deal, task, contact)
    name = contact && (contact["name"] || contact["email"] || contact["handle"])
    title = task && task["title"]
    amount = deal && money(deal["value"] || 0)
    amount = 720 if amount.to_f <= 0

    "Oi#{name ? " #{name}" : ""}, obrigado pelo retorno. Posso seguir com os próximos passos para #{title || "essa demanda"}. A proposta fica em R$ #{format_money(amount)} via Pix. Posso te mandar a cobrança agora?"
  end

  def update_event_action(event_id, status, note)
    @db.execute(
      <<~SQL,
        UPDATE response_inbox_events
        SET action_status = ?,
            action_note = ?,
            actioned_at = ?
        WHERE id = ?
      SQL
      [status, note, Time.now.iso8601, event_id]
    )
  end

  def record_action(event, action_type, note)
    @db.execute(
      <<~SQL,
        INSERT INTO response_actions
        (
          response_event_id,
          deal_id,
          task_id,
          contact_id,
          action_type,
          status,
          note,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        event["id"],
        event["deal_id"],
        event["task_id"],
        event["contact_id"],
        action_type,
        "done",
        note,
        Time.now.iso8601
      ]
    )
  end

  def notify(kind, title, body, link)
    return unless defined?(SystemNotifier)

    SystemNotifier.new(@db).notify(
      kind: kind,
      title: title,
      body: body,
      link: link,
      dedupe_key: "#{kind}_#{Time.now.to_i}"
    )
  rescue
  end

  def find_event(id)
    one("SELECT * FROM response_inbox_events WHERE id = ?", [id])
  end

  def money(value)
    value.to_s.gsub(/[^\d.,-]/, "").tr(",", ".").to_f
  end

  def format_money(value)
    "%.2f" % value.to_f
  end

  def scalar(sql, params = [])
    @db.get_first_value(sql, params).to_i
  rescue
    row = @db.get_first_row(sql, params)
    row.is_a?(Hash) ? row.values.first.to_i : row.to_a.first.to_i
  end

  def one(sql, params = [])
    row = @db.get_first_row(sql, params)
    row&.reject { |k, _| k.is_a?(Integer) }
  end

  def all(sql, params = [])
    @db.execute(sql, params).map { |row| row.reject { |k, _| k.is_a?(Integer) } }
  end
end
