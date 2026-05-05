class OutreachPolicy
  BLOCKED_TITLE_PATTERNS = [
    /cve/i,
    /vulnerability/i,
    /exploit/i,
    /security/i,
    /credential/i,
    /token/i,
    /password/i
  ]

  RECENT_CONTACT_DAYS = 7

  def initialize(db)
    @db = db
  end

  def allowed?(task:, deal:, contact:, channel: "manual_provider")
    return deny("missing_task") unless task
    return deny("missing_deal") unless deal
    return deny("missing_contact") unless contact

    if task["quality_status"] != "monetizable"
      return deny("task_not_monetizable")
    end

    if task["quality_reason"].to_s.include?("security_sensitive")
      return deny("security_sensitive")
    end

    if BLOCKED_TITLE_PATTERNS.any? { |pattern| task["title"].to_s.match?(pattern) }
      return deny("blocked_security_pattern")
    end

    if do_not_contact?(contact)
      return deny("do_not_contact")
    end

    if recently_contacted?(contact)
      return deny("recently_contacted")
    end

    if daily_limit_reached?(channel)
      return deny("daily_limit_reached")
    end

    allow("policy_approved")
  end

  private

  def allow(reason)
    {
      allowed: true,
      risk_level: "low",
      reason: reason
    }
  end

  def deny(reason)
    {
      allowed: false,
      risk_level: "blocked",
      reason: reason
    }
  end

  def do_not_contact?(contact)
    value = contact["email"].to_s.strip
    handle = contact["handle"].to_s.strip

    rows = @db.execute(
      <<~SQL,
        SELECT *
        FROM do_not_contact_entries
        WHERE contact_id = ?
           OR value = ?
           OR value = ?
        LIMIT 1
      SQL
      [contact["id"], value, handle]
    )

    !rows.empty?
  end

  def recently_contacted?(contact)
    rows = @db.execute(
      <<~SQL,
        SELECT *
        FROM outreach_messages
        WHERE contact_id = ?
          AND status IN ('sent', 'replied', 'followup_sent')
          AND datetime(sent_at) >= datetime('now', ?)
        LIMIT 1
      SQL
      [contact["id"], "-#{RECENT_CONTACT_DAYS} days"]
    )

    !rows.empty?
  end

  def daily_limit_reached?(channel)
    limit_row = @db.get_first_row(
      "SELECT limit_value FROM outreach_limits WHERE limit_key = ?",
      ["daily_#{channel}"]
    )

    limit = limit_row ? limit_row["limit_value"].to_i : 20

    count_row = @db.get_first_row(
      <<~SQL,
        SELECT COUNT(*) AS c
        FROM outreach_messages
        WHERE provider = ?
          AND status IN ('sent', 'replied', 'followup_sent')
          AND date(sent_at) = date('now')
      SQL
      [channel]
    )

    count_row["c"].to_i >= limit
  end
end
