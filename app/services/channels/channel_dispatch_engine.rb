require "time"
require "net/smtp"

class ChannelDispatchEngine
  DAILY_LIMIT = 20

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
    provider = dispatch["provider"].to_s

    case provider
    when "smtp_email"
      send_smtp(dispatch)
    else
      mark_manual(dispatch)
    end
  rescue => e
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        UPDATE channel_dispatches
        SET status = 'failed',
            attempts = attempts + 1,
            last_error = ?,
            updated_at = ?
        WHERE id = ?
      SQL
      ["#{e.class}: #{e.message}", now, dispatch["id"]]
    )
  end

  private

  def dispatch_provider
    provider =
      if defined?(AppSettings)
        AppSettings.get("EMAIL_PROVIDER").to_s
      else
        ENV["EMAIL_PROVIDER"].to_s
      end

    enabled =
      if defined?(AppSettings)
        AppSettings.get("CHANNEL_DISPATCH_ENABLED").to_s == "true"
      else
        ENV["CHANNEL_DISPATCH_ENABLED"].to_s == "true"
      end

    return "smtp_email" if provider == "smtp" && enabled

    "manual_channel"
  end

  def policy_check(message, provider, recipient)
    return deny("missing_message") unless message
    return deny("missing_contact") if message["contact_id"].to_s.empty?

    if provider == "smtp_email" && recipient.empty?
      return deny("missing_email_for_smtp")
    end

    if daily_limit_reached?(provider)
      return deny("daily_limit_reached")
    end

    if already_sent_to_contact_recently?(message["contact_id"])
      return deny("recent_contact_dispatch")
    end

    allow("dispatch_allowed")
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

    row["c"].to_i >= DAILY_LIMIT
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
          created_at,
          updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
    from = user.to_s.strip

    raise "SMTP_HOST missing" if host.to_s.strip.empty?
    raise "SMTP_USER missing" if user.to_s.strip.empty?
    raise "SMTP_PASSWORD missing" if pass.to_s.strip.empty?
    raise "recipient missing" if dispatch["recipient"].to_s.strip.empty?

    port = 587 if port <= 0

    message = <<~MAIL
      From: #{from}
      To: #{dispatch["recipient"]}
      Subject: #{dispatch["subject"]}

      #{dispatch["body"]}
    MAIL

    Net::SMTP.start(host, port, "localhost", user, pass, :plain) do |smtp|
      smtp.enable_starttls_auto
      smtp.send_message(message, from, dispatch["recipient"])
    end

    mark_sent(dispatch, "smtp_email_sent")
  end

  def mark_manual(dispatch)
    mark_sent(dispatch, "manual_channel_marked_sent")
  end

  def mark_sent(dispatch, reason)
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        UPDATE channel_dispatches
        SET status = 'sent',
            attempts = attempts + 1,
            last_error = NULL,
            policy_reason = ?,
            updated_at = ?,
            sent_at = ?
        WHERE id = ?
      SQL
      [reason, now, now, dispatch["id"]]
    )
  end

  def setting(key)
    if defined?(AppSettings)
      AppSettings.get(key).to_s
    else
      ENV[key].to_s
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
