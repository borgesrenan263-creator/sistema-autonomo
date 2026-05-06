require "time"

class StaleDealCloser
  def initialize(db)
    @db = db
  end

  def preview(days: 7, limit: 30)
    stale_candidates(days: days, limit: limit)
  end

  def run_once(days: 7, limit: 30)
    candidates = stale_candidates(days: days, limit: limit)

    candidates.map do |deal|
      close_deal(deal, days: days)
    end
  end

  private

  def stale_candidates(days:, limit:)
    cutoff = (Time.now.utc - (days.to_i * 86_400)).iso8601

    rows(
      <<~SQL,
        SELECT d.*
        FROM deals d
        WHERE d.status = 'proposta_criada'
          AND d.followup_status = 'proposal_followup_sent'
          AND d.last_followup_at IS NOT NULL
          AND datetime(d.last_followup_at) <= datetime(?)
          AND NOT EXISTS (
            SELECT 1
            FROM payments p
            WHERE p.deal_id = d.id
              AND p.status IN ('pending', 'paid')
            LIMIT 1
          )
          AND NOT EXISTS (
            SELECT 1
            FROM responses r
            WHERE r.deal_id = d.id
              AND r.response_status = 'interested'
              AND r.signature_valid = 1
            LIMIT 1
          )
        ORDER BY d.last_followup_at ASC, d.value DESC
        LIMIT ?
      SQL
      [cutoff, limit]
    )
  end

  def close_deal(deal, days:)
    now = Time.now.utc.iso8601

    @db.execute(
      <<~SQL,
        UPDATE deals
        SET status = 'perdido',
            next_action = ?,
            closed_at = ?,
            updated_at = ?
        WHERE id = ?
      SQL
      [
        "Auto-close: sem resposta após #{days} dias desde o último follow-up.",
        now,
        now,
        deal["id"]
      ]
    )

    log_event(
      deal["id"],
      "auto_closed_lost",
      "Deal marcado como perdido automaticamente",
      "Sem resposta após #{days} dias desde last_followup_at=#{deal["last_followup_at"]}."
    )

    {
      id: deal["id"],
      task_id: deal["task_id"],
      status: "perdido",
      value: deal["value"],
      reason: "stale_after_#{days}_days"
    }
  end

  def log_event(deal_id, event_type, title, detail)
    return unless table_exists?("deal_events")

    @db.execute(
      <<~SQL,
        INSERT INTO deal_events
        (
          deal_id,
          event_type,
          title,
          detail,
          created_at
        )
        VALUES (?, ?, ?, ?, ?)
      SQL
      [deal_id, event_type, title, detail, Time.now.utc.iso8601]
    )
  rescue
    nil
  end

  def table_exists?(name)
    !!@db.get_first_value(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [name]
    )
  end

  def rows(sql, params = [])
    @db.execute(sql, params).map { |r| clean(r) }
  rescue
    []
  end

  def clean(row)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
