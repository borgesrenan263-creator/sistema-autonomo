require "json"
require "time"
require "openssl"

class ResponseInboxProvider
  def initialize(db)
    @db = db
  end

  def handle_webhook(raw_body:, headers: {})
    payload = parse_json(raw_body)
    secret_ok = valid_secret?(headers)

    event_id = value(payload, "event_id") || value(payload, "id") || value(payload, "message_id")
    sender = value(payload, "sender") || value(payload, "from") || value(payload, "email")
    recipient = value(payload, "recipient") || value(payload, "to")
    subject = value(payload, "subject")
    body = value(payload, "body") || value(payload, "text") || value(payload, "message")
    channel = value(payload, "channel") || "webhook"
    provider = value(payload, "provider") || "generic_response"

    explicit_status = value(payload, "response_status") || value(payload, "status")
    response_status = normalize_response_status(explicit_status, body)

    event = register_event(
      event_id: event_id,
      provider: provider,
      channel: channel,
      sender: sender,
      recipient: recipient,
      subject: subject,
      body: body,
      response_status: response_status,
      raw_body: raw_body,
      signature_valid: secret_ok ? 1 : 0
    )

    unless secret_ok
      mark_event_error(event["id"], "invalid_response_webhook_secret")
      return { ok: false, status: 401, message: "invalid_response_webhook_secret" }
    end

    if event_already_processed?(event)
      return { ok: true, status: 200, message: "already_processed", event_id: event["id"] }
    end

    target = find_target(payload, sender, subject, body)

    unless target
      mark_event_error(event["id"], "target_not_found")
      return { ok: false, status: 404, message: "target_not_found", event_id: event["id"] }
    end

    process_response(event, target, response_status, body)

    if defined?(ConciergeAutopilot)
      ConciergeAutopilot.new(@db).run_once
    end

    notify_response(target, response_status)

    { ok: true, status: 200, message: "response_processed", event_id: event["id"], response_status: response_status }
  rescue => e
    { ok: false, status: 500, message: "#{e.class}: #{e.message}" }
  end

  private

  def parse_json(raw_body)
    JSON.parse(raw_body.to_s.empty? ? "{}" : raw_body)
  rescue JSON::ParserError
    {}
  end

  def value(payload, key)
    payload[key] || payload[key.to_sym]
  end

  def valid_secret?(headers)
    expected =
      if defined?(AppSettings)
        AppSettings.get("RESPONSE_WEBHOOK_SECRET").to_s
      else
        ENV["RESPONSE_WEBHOOK_SECRET"].to_s
      end

    return false if expected.empty?
    return false if expected == "trocar_em_producao"

    received =
      headers["HTTP_X_RESPONSE_SECRET"] ||
      headers["X-RESPONSE-SECRET"] ||
      headers["x-response-secret"]

    secure_compare(expected, received.to_s)
  end

  def secure_compare(a, b)
    return false if a.bytesize != b.bytesize
    OpenSSL.fixed_length_secure_compare(a, b)
  rescue
    a == b
  end

  def normalize_response_status(explicit_status, body)
    status = explicit_status.to_s.downcase.strip

    return "interested" if ["interested", "sim", "yes", "positivo", "accepted", "accept"].include?(status)
    return "not_interested" if ["not_interested", "nao", "não", "no", "negative", "rejected", "reject"].include?(status)
    return "needs_more_info" if ["needs_more_info", "duvida", "dúvida", "question", "more_info"].include?(status)

    text = body.to_s.downcase

    interested_words = ["tenho interesse", "interesse", "pode mandar", "quero", "sim", "vamos", "aceito", "ok"]
    negative_words = ["não tenho interesse", "nao tenho interesse", "não quero", "nao quero", "sem interesse", "pare", "remover"]
    more_info_words = ["quanto", "como funciona", "me explica", "detalhes", "dúvida", "duvida"]

    return "not_interested" if negative_words.any? { |w| text.include?(w) }
    return "needs_more_info" if more_info_words.any? { |w| text.include?(w) }
    return "interested" if interested_words.any? { |w| text.include?(w) }

    "needs_more_info"
  end

  def register_event(event_id:, provider:, channel:, sender:, recipient:, subject:, body:, response_status:, raw_body:, signature_valid:)
    now = Time.now.iso8601

    existing =
      if event_id && !event_id.to_s.empty?
        one("SELECT * FROM response_inbox_events WHERE event_id = ? ORDER BY id DESC LIMIT 1", [event_id])
      end

    return existing if existing

    @db.execute(
      <<~SQL,
        INSERT INTO response_inbox_events
        (
          event_id,
          provider,
          channel,
          sender,
          recipient,
          subject,
          body,
          response_status,
          raw_body,
          signature_valid,
          processed,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        event_id,
        provider,
        channel,
        sender,
        recipient,
        subject,
        body,
        response_status,
        raw_body,
        signature_valid,
        0,
        now
      ]
    )

    one("SELECT * FROM response_inbox_events WHERE id = ?", [@db.last_insert_row_id])
  end

  def event_already_processed?(event)
    event && event["processed"].to_i == 1
  end

  def find_target(payload, sender, subject, body)
    outreach_id = value(payload, "outreach_message_id")
    flow_id = value(payload, "flow_id")
    deal_id = value(payload, "deal_id")
    contact_id = value(payload, "contact_id")

    if outreach_id
      target = one("SELECT * FROM outreach_messages WHERE id = ?", [outreach_id])
      return enrich_target(target) if target
    end

    if flow_id
      target = one("SELECT * FROM outreach_messages WHERE flow_id = ? ORDER BY id DESC LIMIT 1", [flow_id])
      return enrich_target(target) if target
    end

    if deal_id
      target = one("SELECT * FROM outreach_messages WHERE deal_id = ? ORDER BY id DESC LIMIT 1", [deal_id])
      return enrich_target(target) if target
    end

    if contact_id
      target = one("SELECT * FROM outreach_messages WHERE contact_id = ? ORDER BY id DESC LIMIT 1", [contact_id])
      return enrich_target(target) if target
    end

    if sender && !sender.to_s.strip.empty?
      contact = one(
        "SELECT * FROM contacts WHERE email = ? OR handle = ? ORDER BY id DESC LIMIT 1",
        [sender, sender]
      )

      if contact
        target = one("SELECT * FROM outreach_messages WHERE contact_id = ? ORDER BY id DESC LIMIT 1", [contact["id"]])
        return enrich_target(target) if target
      end
    end

    ref = extract_reference(subject.to_s + " " + body.to_s)

    if ref
      target = one("SELECT * FROM outreach_messages WHERE deal_id = ? ORDER BY id DESC LIMIT 1", [ref])
      return enrich_target(target) if target
    end

    nil
  end

  def enrich_target(target)
    return nil unless target

    flow = one("SELECT * FROM automation_flows WHERE id = ?", [target["flow_id"]])
    deal = one("SELECT * FROM deals WHERE id = ?", [target["deal_id"]])
    task = flow ? one("SELECT * FROM tasks WHERE id = ?", [flow["task_id"]]) : nil

    target.merge(
      "flow" => flow,
      "deal" => deal,
      "task" => task
    )
  end

  def extract_reference(text)
    match = text.match(/deal[-_\s#]*(\d+)/i)
    match ? match[1].to_i : nil
  end

  def process_response(event, target, response_status, body)
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        UPDATE outreach_messages
        SET status = 'replied',
            response_status = ?,
            reply_body = ?,
            replied_at = ?,
            updated_at = ?
        WHERE id = ?
      SQL
      [response_status, body, now, now, target["id"]]
    )

    update_deal_and_flow(target, response_status, now)

    @db.execute(
      <<~SQL,
        UPDATE response_inbox_events
        SET processed = 1,
            processing_error = NULL,
            outreach_message_id = ?,
            flow_id = ?,
            deal_id = ?,
            contact_id = ?,
            task_id = ?,
            processed_at = ?
        WHERE id = ?
      SQL
      [
        target["id"],
        target["flow_id"],
        target["deal_id"],
        target["contact_id"],
        target["flow"] ? target["flow"]["task_id"] : nil,
        now,
        event["id"]
      ]
    )

    create_outreach_event(target, response_status, body)
  end

  def update_deal_and_flow(target, response_status, now)
    case response_status
    when "interested"
      @db.execute("UPDATE deals SET status = 'interessado', updated_at = ? WHERE id = ?", [now, target["deal_id"]])
      @db.execute(
        "UPDATE automation_flows SET current_state = 'interested', next_action = 'create_payment', status = 'running', last_error = NULL, updated_at = ? WHERE id = ?",
        [now, target["flow_id"]]
      )
    when "not_interested"
      @db.execute("UPDATE deals SET status = 'perdido', updated_at = ? WHERE id = ?", [now, target["deal_id"]])
      @db.execute(
        "UPDATE automation_flows SET current_state = 'lost', next_action = NULL, status = 'lost', last_error = NULL, updated_at = ?, completed_at = ? WHERE id = ?",
        [now, now, target["flow_id"]]
      )
    else
      @db.execute(
        "UPDATE automation_flows SET current_state = 'outreach_sent', next_action = 'wait_interest', status = 'blocked', last_error = 'needs_more_info', updated_at = ? WHERE id = ?",
        [now, target["flow_id"]]
      )
    end
  end

  def create_outreach_event(target, response_status, body)
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
        target["id"],
        target["flow_id"],
        target["deal_id"],
        "response_inbox_received",
        "Resposta recebida via webhook",
        body.to_s[0, 500],
        "response_status=#{response_status}",
        Time.now.iso8601
      ]
    )
  end

  def notify_response(target, response_status)
    return unless defined?(SystemNotifier)

    title =
      case response_status
      when "interested"
        "Contato interessado"
      when "not_interested"
        "Contato não interessado"
      else
        "Contato pediu mais informações"
      end

    SystemNotifier.new(@db).notify(
      kind: "response_received",
      title: title,
      body: "Resposta recebida para o Deal ##{target["deal_id"]}. Status: #{response_status}.",
      link: "/deals/#{target["deal_id"]}",
      dedupe_key: "response_received_#{target["id"]}_#{response_status}"
    )
  end

  def mark_event_error(event_id, error)
    @db.execute(
      "UPDATE response_inbox_events SET processing_error = ? WHERE id = ?",
      [error, event_id]
    )
  end

  def one(sql, params = [])
    row = @db.get_first_row(sql, params)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
