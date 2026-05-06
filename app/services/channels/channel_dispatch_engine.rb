require "time"
require "net/smtp"
require "securerandom"

class ChannelDispatchEngine
  DEFAULT_DAILY_LIMIT = 20

  def initialize(db)
    @db = db
  end

  def sync_outbox
    messages = all(
      <<~SQL
        SELECT
          outreach_messages.*,
          contacts.email AS contact_email,
          contacts.handle AS contact_handle,
          contacts.platform AS contact_platform,
          contacts.name AS contact_name
        FROM outreach_messages
        LEFT JOIN contacts ON contacts.id = outreach_messages.contact_id
        WHERE outreach_messages.policy_status = 'approved'
          AND outreach_messages.status IN ('sent', 'policy_approved', 'queued')
        ORDER BY outreach_messages.id DESC
        LIMIT 100
      SQL
    )

    messages.each do |message|
      next if existing_dispatch?(message["id"])

      provider = dispatch_provider
      recipient = message["contact_email"].to_s.strip
      policy = policy_check(message, provider, recipient)

      create_dispatch(message, provider, recipient, policy)
    end
  end

  def run_once
    sync_outbox

    queued = all(
      <<~SQL
        SELECT *
        FROM channel_dispatches
        WHERE status = 'queued'
          AND policy_status = 'approved'
        ORDER BY id ASC
        LIMIT 20
      SQL
    )

    queued.each { |dispatch| send_dispatch(dispatch) }
  end

  def send_dispatch(dispatch)
    return mark_blocked(dispatch, "outside_send_window") unless inside_send_window?

    provider = dispatch["provider"].to_s

    case provider
    when "smtp_email"
      send_smtp(dispatch)
    else
      mark_manual(dispatch)
    end
  rescue => e
    mark_failed(dispatch, "#{e.class}: #{e.message}")
  end

  private

  def dispatch_provider
    email_provider = setting("EMAIL_PROVIDER")
    enabled = setting("CHANNEL_DISPATCH_ENABLED") == "true"

    return "smtp_email" if enabled && email_provider == "smtp"

    "manual_channel"
  end

  def policy_check(message, provider, recipient)
    return deny("missing_message") unless message
    return deny("missing_contact") if message["contact_id"].to_s.empty?

    if provider == "smtp_email"
      return deny("missing_email_for_smtp") if recipient.empty?
      return deny("smtp_not_configured") unless smtp_configured?
    end

    return deny("outside_send_window") unless inside_send_window?
    return deny("daily_limit_reached") if daily_limit_reached?(provider)
    return deny("recent_contact_dispatch") if already_sent_to_contact_recently?(message["contact_id"])

    allow("dispatch_allowed")
  end

  def smtp_configured?
    !setting("SMTP_HOST").empty? &&
      !setting("SMTP_USER").empty? &&
      !setting("SMTP_PASSWORD").empty?
  end

  def daily_limit
    value = setting("CHANNEL_DAILY_LIMIT").to_i
    value > 0 ? value : DEFAULT_DAILY_LIMIT
  end

  def daily_limit_reached?(provider)
    row = one(
      <<~SQL,
        SELECT COUNT(*) AS c
        FROM channel_dispatches
        WHERE provider = ?
          AND status = 'sent'
          AND date(sent_at) = date('now')
      SQL
      [provider]
    )

    row["c"].to_i >= daily_limit
  end

  def inside_send_window?
    start_time = setting("CHANNEL_SEND_WINDOW_START")
    end_time = setting("CHANNEL_SEND_WINDOW_END")

    return true if start_time.empty? || end_time.empty?

    now = Time.now
    current = now.strftime("%H:%M")

    current >= start_time && current <= end_time
  end

  def already_sent_to_contact_recently?(contact_id)
    row = one(
      <<~SQL,
        SELECT *
        FROM channel_dispatches
        WHERE contact_id = ?
          AND status = 'sent'
          AND datetime(sent_at) >= datetime('now', '-7 days')
        LIMIT 1
      SQL
      [contact_id]
    )

    !!row
  end

  def create_dispatch(message, provider, recipient, policy)
    now = Time.now.iso8601
    status = policy[:allowed] ? "queued" : "blocked"

    @db.execute(
      <<~SQL,
        INSERT INTO channel_dispatches
        (
          outreach_message_id,
          flow_id,
          deal_id,
          contact_id,
          channel,
          provider,
          recipient,
          subject,
          body,
          status,
          policy_status,
          policy_reason,
          send_window_status,
          created_at,
          updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        message["id"],
        message["flow_id"],
        message["deal_id"],
        message["contact_id"],
        "email",
        provider,
        recipient,
        message["subject"],
        message["message_body"],
        status,
        policy[:allowed] ? "approved" : "denied",
        policy[:reason],
        inside_send_window? ? "inside_window" : "outside_window",
        now,
        now
      ]
    )
  end

  def send_smtp(dispatch)
    host = setting("SMTP_HOST")
    port = setting("SMTP_PORT").to_i
    user = setting("SMTP_USER")
    pass = setting("SMTP_PASSWORD")
    from = setting("SMTP_FROM")
    from = user if from.empty?

    raise "SMTP_HOST missing" if host.empty?
    raise "SMTP_USER missing" if user.empty?
    raise "SMTP_PASSWORD missing" if pass.empty?
    raise "recipient missing" if dispatch["recipient"].to_s.strip.empty?

    port = 587 if port <= 0

    message_id = "sa-#{SecureRandom.hex(12)}@sistema-autonomo.local"

    message = <<~MAIL
      From: #{from}
      To: #{dispatch["recipient"]}
      Subject: #{dispatch["subject"]}
      Message-ID: <#{message_id}>

      #{dispatch["body"]}
    MAIL

    Net::SMTP.start(host, port, "localhost", user, pass, :plain) do |smtp|
      smtp.enable_starttls_auto
      smtp.send_message(message, from, dispatch["recipient"])
    end

    mark_sent(dispatch, "smtp_email_sent", message_id)
  end

  def mark_manual(dispatch)
    mark_sent(dispatch, "manual_channel_marked_sent", nil)
  end

  def mark_sent(dispatch, reason, external_message_id)
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        UPDATE channel_dispatches
        SET status = 'sent',
            attempts = attempts + 1,
            last_error = NULL,
            policy_reason = ?,
            external_message_id = COALESCE(external_message_id, ?),
            delivery_log = ?,
            updated_at = ?,
            sent_at = ?,
            completed_at = ?
        WHERE id = ?
      SQL
      [
        reason,
        external_message_id,
        "sent_by=#{dispatch["provider"]};reason=#{reason}",
        now,
        now,
        now,
        dispatch["id"]
      ]
    )
  end

  def mark_failed(dispatch, error)
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        UPDATE channel_dispatches
        SET status = 'failed',
            attempts = attempts + 1,
            last_error = ?,
            delivery_log = ?,
            updated_at = ?
        WHERE id = ?
      SQL
      [error, error, now, dispatch["id"]]
    )
  end

  def mark_blocked(dispatch, reason)
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        UPDATE channel_dispatches
        SET status = 'blocked',
            policy_status = 'denied',
            policy_reason = ?,
            send_window_status = 'outside_window',
            updated_at = ?
        WHERE id = ?
      SQL
      [reason, now, dispatch["id"]]
    )
  end

  def setting(key)
    if defined?(AppSettings)
      AppSettings.get(key).to_s.strip
    else
      ENV[key].to_s.strip
    end
  end

  def existing_dispatch?(outreach_message_id)
    !!one("SELECT * FROM channel_dispatches WHERE outreach_message_id = ? LIMIT 1", [outreach_message_id])
  end

  def allow(reason)
    { allowed: true, reason: reason }
  end

  def deny(reason)
    { allowed: false, reason: reason }
  end

  def one(sql, params = [])
    row = @db.get_first_row(sql, params)
    row&.reject { |k, _| k.is_a?(Integer) }
  end

  def all(sql, params = [])
    @db.execute(sql, params).map { |row| row.reject { |k, _| k.is_a?(Integer) } }
  end
end
