require "time"
require "json"

class DispatchAutopilotEngine
  SAFE_START = "08:00"
  SAFE_END = "22:00"

  def initialize(db)
    @db = db
  end

  def dashboard
    {
      generated_at: Time.now.iso8601,
      config: config,
      counts: counts,
      candidates: candidates,
      latest_runs: latest_runs,
      latest_events: latest_events,
      daily_usage: daily_usage
    }
  end

  def run(limit = nil)
    limit ||= ENV.fetch("DISPATCH_AUTOPILOT_BATCH_LIMIT", "10").to_i
    limit = 10 if limit <= 0

    now = Time.now.iso8601
    selected = candidates.first(limit)

    run_id = create_run(selected.size)

    counters = {
      sent: 0,
      manual: 0,
      blocked: 0,
      failed: 0
    }

    selected.each do |message|
      result = process_message(message, run_id)

      case result[:status]
      when "sent"
        counters[:sent] += 1
      when "manual"
        counters[:manual] += 1
      when "blocked"
        counters[:blocked] += 1
      else
        counters[:failed] += 1
      end
    rescue => e
      counters[:failed] += 1
      record_event(run_id, message && message["id"], nil, "failed", "failed", "#{e.class}: #{e.message}")
    end

    summary = "sent=#{counters[:sent]} manual=#{counters[:manual]} blocked=#{counters[:blocked]} failed=#{counters[:failed]}"

    @db.execute(
      <<~SQL,
        UPDATE dispatch_autopilot_runs
        SET status = ?,
            sent_count = ?,
            manual_count = ?,
            blocked_count = ?,
            failed_count = ?,
            summary = ?,
            finished_at = ?
        WHERE id = ?
      SQL
      [
        "done",
        counters[:sent],
        counters[:manual],
        counters[:blocked],
        counters[:failed],
        summary,
        Time.now.iso8601,
        run_id
      ]
    )

    one("SELECT * FROM dispatch_autopilot_runs WHERE id = ?", [run_id])
  end

  def process_one(outreach_message_id)
    message = one("SELECT * FROM outreach_messages WHERE id = ?", [outreach_message_id])
    raise "Mensagem não encontrada" unless message

    run_id = create_run(1)
    result = process_message(message, run_id)

    @db.execute(
      <<~SQL,
        UPDATE dispatch_autopilot_runs
        SET status = ?,
            sent_count = ?,
            manual_count = ?,
            blocked_count = ?,
            failed_count = ?,
            summary = ?,
            finished_at = ?
        WHERE id = ?
      SQL
      [
        "done",
        result[:status] == "sent" ? 1 : 0,
        result[:status] == "manual" ? 1 : 0,
        result[:status] == "blocked" ? 1 : 0,
        result[:status] == "failed" ? 1 : 0,
        result[:reason],
        Time.now.iso8601,
        run_id
      ]
    )

    result
  end

  private

  def process_message(message, run_id)
    already = existing_dispatch(message["id"])

    if already
      update_message(message["id"], "skipped", "dispatch já existe ##{already["id"]}")
      record_event(run_id, message["id"], already["id"], "skipped", "blocked", "dispatch já existe")
      return { status: "blocked", reason: "dispatch_exists" }
    end

    unless message["policy_status"].to_s == "approved"
      update_message(message["id"], "blocked", "policy_status não aprovado")
      record_event(run_id, message["id"], nil, "blocked", "blocked", "policy_status não aprovado")
      return { status: "blocked", reason: "policy_not_approved" }
    end

    unless inside_send_window?
      update_message(message["id"], "queued", "fora da janela segura")
      record_event(run_id, message["id"], nil, "queued", "blocked", "fora da janela segura")
      return { status: "blocked", reason: "outside_send_window" }
    end

    if daily_limit_reached?
      update_message(message["id"], "queued", "limite diário atingido")
      record_event(run_id, message["id"], nil, "queued", "blocked", "limite diário atingido")
      return { status: "blocked", reason: "daily_limit_reached" }
    end

    recipient = resolve_recipient(message)

    if recipient.to_s.strip.empty?
      dispatch = create_dispatch(message, "manual_channel", nil, "sent", "approved", "manual_channel_missing_recipient")
      mark_message_dispatched(message["id"], "manual", "Sem destinatário; marcado para canal manual.")
      record_event(run_id, message["id"], dispatch["id"], "manual", "manual", "Sem destinatário; canal manual.")
      return { status: "manual", reason: "missing_recipient" }
    else
      update_message(message["id"], "recipient_resolved", "Destinatário resolvido: #{recipient}")
      record_event(run_id, message["id"], nil, "recipient_resolved", "ok", "Destinatário resolvido: #{recipient}")
    end

    unless dispatch_enabled?
      dispatch = create_dispatch(message, "manual_channel", recipient, "sent", "approved", "manual_channel_dispatch_disabled")
      mark_message_dispatched(message["id"], "manual", "Dispatch real desativado; canal manual.")
      record_event(run_id, message["id"], dispatch["id"], "manual", "manual", "Dispatch real desativado.")
      return { status: "manual", reason: "dispatch_disabled" }
    end

    if email_provider == "smtp"
      send_or_delegate_smtp(message, recipient, run_id)
    else
      dispatch = create_dispatch(message, "manual_channel", recipient, "sent", "approved", "manual_channel_provider_not_smtp")
      mark_message_dispatched(message["id"], "manual", "Provider não SMTP; canal manual.")
      record_event(run_id, message["id"], dispatch["id"], "manual", "manual", "Provider não SMTP.")
      { status: "manual", reason: "provider_not_smtp" }
    end
  end

  def send_or_delegate_smtp(message, recipient, run_id)
    if defined?(ChannelDispatcher)
      # Se o projeto já tiver dispatcher real, preferimos delegar para ele criando dispatch queued.
      dispatch = create_dispatch(message, "smtp_email", recipient, "queued", "approved", "dispatch_allowed")
      mark_message_dispatched(message["id"], "queued", "Dispatch SMTP enfileirado para provider real.")
      record_event(run_id, message["id"], dispatch["id"], "queued", "sent", "SMTP enfileirado.")
      return { status: "sent", reason: "smtp_queued" }
    end

    dispatch = create_dispatch(message, "smtp_email", recipient, "queued", "approved", "dispatch_allowed")
    mark_message_dispatched(message["id"], "queued", "SMTP enfileirado.")
    record_event(run_id, message["id"], dispatch["id"], "queued", "sent", "SMTP enfileirado.")
    { status: "sent", reason: "smtp_queued" }
  end

  def create_dispatch(message, provider, recipient, status, policy_status, policy_reason)
    now = Time.now.iso8601

    return one("SELECT * FROM channel_dispatches WHERE outreach_message_id = ? ORDER BY id DESC LIMIT 1", [message["id"]]) unless table_exists?("channel_dispatches")

    columns = []
    values = []

    {
      "outreach_message_id" => message["id"],
      "provider" => provider,
      "recipient" => recipient,
      "status" => status,
      "policy_status" => policy_status,
      "policy_reason" => policy_reason,
      "created_at" => now,
      "updated_at" => now
    }.each do |col, val|
      if table_has_column?("channel_dispatches", col)
        columns << col
        values << val
      end
    end

    placeholders = (["?"] * columns.length).join(", ")
    @db.execute("INSERT INTO channel_dispatches (#{columns.join(", ")}) VALUES (#{placeholders})", values)

    one("SELECT * FROM channel_dispatches WHERE id = ?", [@db.last_insert_row_id])
  end

  def mark_message_dispatched(id, status, note)
    update_message(id, status, note)

    if table_has_column?("outreach_messages", "status")
      new_status = status == "manual" ? "queued" : "queued"
      @db.execute("UPDATE outreach_messages SET status = ? WHERE id = ?", [new_status, id])
    end
  end

  def update_message(id, status, note)
    return unless table_exists?("outreach_messages")

    updates = []
    values = []

    if table_has_column?("outreach_messages", "dispatch_autopilot_status")
      updates << "dispatch_autopilot_status = ?"
      values << status
    end

    if table_has_column?("outreach_messages", "dispatch_autopilot_note")
      updates << "dispatch_autopilot_note = ?"
      values << note
    end

    if table_has_column?("outreach_messages", "dispatch_autopilot_at")
      updates << "dispatch_autopilot_at = ?"
      values << Time.now.iso8601
    end

    return if updates.empty?

    values << id
    @db.execute("UPDATE outreach_messages SET #{updates.join(", ")} WHERE id = ?", values)
  end

  def existing_dispatch(outreach_message_id)
    return nil unless table_exists?("channel_dispatches")
    one("SELECT * FROM channel_dispatches WHERE outreach_message_id = ? ORDER BY id DESC LIMIT 1", [outreach_message_id])
  end

  def resolve_recipient(message)
    direct = resolve_direct_contact_email(message)
    return direct if present?(direct)

    from_deal = resolve_deal_contact_email(message)
    return from_deal if present?(from_deal)

    from_response = resolve_response_contact_email(message)
    return from_response if present?(from_response)

    from_task = resolve_task_contact_email(message)
    return from_task if present?(from_task)

    from_raw_json = resolve_raw_json_email(message)
    return from_raw_json if present?(from_raw_json)

    nil
  rescue
    nil
  end

  def resolve_direct_contact_email(message)
    contact_id = message["contact_id"] if message.key?("contact_id")
    return nil unless contact_id && table_exists?("contacts")

    contact = one("SELECT * FROM contacts WHERE id = ?", [contact_id])
    email_from_contact(contact)
  end

  def resolve_deal_contact_email(message)
    deal_id = message["deal_id"] if message.key?("deal_id")
    return nil unless deal_id && table_exists?("deals")

    deal = one("SELECT * FROM deals WHERE id = ?", [deal_id])
    return nil unless deal

    if deal["contact_id"] && table_exists?("contacts")
      contact = one("SELECT * FROM contacts WHERE id = ?", [deal["contact_id"]])
      email = email_from_contact(contact)
      return email if present?(email)
    end

    if deal["task_id"] && table_exists?("tasks")
      task = one("SELECT * FROM tasks WHERE id = ?", [deal["task_id"]])
      email = email_from_task(task)
      return email if present?(email)
    end

    nil
  end

  def resolve_response_contact_email(message)
    return nil unless table_exists?("response_inbox_events")

    event = nil

    if message["deal_id"]
      event = one(
        "SELECT * FROM response_inbox_events WHERE deal_id = ? ORDER BY id DESC LIMIT 1",
        [message["deal_id"]]
      )
    end

    if !event && message["contact_id"]
      event = one(
        "SELECT * FROM response_inbox_events WHERE contact_id = ? ORDER BY id DESC LIMIT 1",
        [message["contact_id"]]
      )
    end

    return nil unless event

    if event["contact_id"] && table_exists?("contacts")
      contact = one("SELECT * FROM contacts WHERE id = ?", [event["contact_id"]])
      email = email_from_contact(contact)
      return email if present?(email)
    end

    email = extract_email(event["sender"].to_s)
    return email if present?(email)

    email = extract_email(event["recipient"].to_s)
    return email if present?(email)

    email = extract_email(event["raw_body"].to_s)
    return email if present?(email)

    nil
  end

  def resolve_task_contact_email(message)
    task_id = message["task_id"] if message.key?("task_id")

    if !task_id && message["deal_id"] && table_exists?("deals")
      deal = one("SELECT * FROM deals WHERE id = ?", [message["deal_id"]])
      task_id = deal && deal["task_id"]
    end

    return nil unless task_id && table_exists?("tasks")

    task = one("SELECT * FROM tasks WHERE id = ?", [task_id])
    email_from_task(task)
  end

  def resolve_raw_json_email(message)
    email = extract_email(message["message_body"].to_s)
    return email if present?(email)

    email = extract_email(message["subject"].to_s)
    return email if present?(email)

    nil
  end

  def email_from_contact(contact)
    return nil unless contact

    ["email", "mail", "recipient"].each do |column|
      if contact.key?(column)
        email = extract_email(contact[column].to_s)
        return email if present?(email)
      end
    end

    nil
  end

  def email_from_task(task)
    return nil unless task

    ["raw_json", "description", "result", "url", "title"].each do |column|
      next unless task.key?(column)

      email = extract_email(task[column].to_s)
      return email if present?(email)
    end

    nil
  end

  def extract_email(text)
    return nil if text.to_s.strip.empty?

    match = text.to_s.match(/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i)
    match && match[0]
  end

  def present?(value)
    !value.nil? && value.to_s.strip != ""
  end

  def candidates
    return [] unless table_exists?("outreach_messages")

    where = []
    where << "status = 'queued'" if table_has_column?("outreach_messages", "status")
    where << "policy_status = 'approved'" if table_has_column?("outreach_messages", "policy_status")

    sql = "SELECT * FROM outreach_messages"
    sql += " WHERE #{where.join(" AND ")}" unless where.empty?
    sql += " ORDER BY id ASC LIMIT 100"

    all(sql)
  rescue
    []
  end

  def counts
    {
      candidates: candidates.count,
      runs: scalar("SELECT COUNT(*) FROM dispatch_autopilot_runs"),
      events: scalar("SELECT COUNT(*) FROM dispatch_autopilot_events"),
      dispatches: table_exists?("channel_dispatches") ? scalar("SELECT COUNT(*) FROM channel_dispatches") : 0,
      today_dispatches: today_dispatch_count
    }
  rescue
    {}
  end

  def daily_usage
    {
      limit: daily_limit,
      used: today_dispatch_count,
      remaining: [daily_limit - today_dispatch_count, 0].max
    }
  end

  def today_dispatch_count
    return 0 unless table_exists?("channel_dispatches")
    today = Time.now.strftime("%Y-%m-%d")
    if table_has_column?("channel_dispatches", "created_at")
      scalar("SELECT COUNT(*) FROM channel_dispatches WHERE created_at LIKE ?", ["#{today}%"])
    else
      0
    end
  rescue
    0
  end

  def daily_limit
    ENV.fetch("CHANNEL_DAILY_LIMIT", "3").to_i
  rescue
    3
  end

  def daily_limit_reached?
    today_dispatch_count >= daily_limit
  end

  def inside_send_window?
    current = Time.now.strftime("%H:%M")
    start_at = ENV.fetch("CHANNEL_SEND_WINDOW_START", ENV.fetch("DISPATCH_WINDOW_START", SAFE_START))
    end_at = ENV.fetch("CHANNEL_SEND_WINDOW_END", ENV.fetch("DISPATCH_WINDOW_END", SAFE_END))

    current >= start_at && current <= end_at
  end

  def dispatch_enabled?
    ENV.fetch("CHANNEL_DISPATCH_ENABLED", "false").to_s == "true"
  end

  def email_provider
    ENV.fetch("EMAIL_PROVIDER", "manual").to_s
  end

  def config
    {
      dispatch_enabled: dispatch_enabled?,
      email_provider: email_provider,
      daily_limit: daily_limit,
      send_window_start: ENV.fetch("CHANNEL_SEND_WINDOW_START", ENV.fetch("DISPATCH_WINDOW_START", SAFE_START)),
      send_window_end: ENV.fetch("CHANNEL_SEND_WINDOW_END", ENV.fetch("DISPATCH_WINDOW_END", SAFE_END))
    }
  end

  def create_run(total)
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        INSERT INTO dispatch_autopilot_runs
        (
          status,
          total_candidates,
          created_at
        )
        VALUES (?, ?, ?)
      SQL
      ["running", total, now]
    )

    @db.last_insert_row_id
  end

  def record_event(run_id, outreach_message_id, dispatch_id, event_type, status, reason)
    @db.execute(
      <<~SQL,
        INSERT INTO dispatch_autopilot_events
        (
          run_id,
          outreach_message_id,
          dispatch_id,
          event_type,
          status,
          reason,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        run_id,
        outreach_message_id,
        dispatch_id,
        event_type,
        status,
        reason,
        Time.now.iso8601
      ]
    )
  end

  def latest_runs
    all("SELECT * FROM dispatch_autopilot_runs ORDER BY id DESC LIMIT 50")
  rescue
    []
  end

  def latest_events
    all("SELECT * FROM dispatch_autopilot_events ORDER BY id DESC LIMIT 100")
  rescue
    []
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

  def one(sql, params = [])
    row = @db.get_first_row(sql, params)
    row&.reject { |k, _| k.is_a?(Integer) }
  end

  def all(sql, params = [])
    @db.execute(sql, params).map { |row| row.reject { |k, _| k.is_a?(Integer) } }
  end
end
