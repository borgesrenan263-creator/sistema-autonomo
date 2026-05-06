require "time"

class OperationalQueueEngine
  def initialize(db)
    @db = db
  end

  def snapshot(limit: 30)
    {
      generated_at: Time.now.utc.iso8601,
      counts: counts,
      stuck_jobs: stuck_jobs,
      latest_jobs: latest_jobs(limit: limit),
      latest_events: latest_events(limit: 20)
    }
  end

  def cancel_job(job_id, reason: "cancelled_by_operator")
    job = row("SELECT * FROM jobs WHERE id = ?", [job_id])
    return { ok: false, error: "job_not_found" } unless job

    unless ["queued", "running"].include?(job["status"].to_s)
      return { ok: false, error: "job_not_cancelable", status: job["status"] }
    end

    now = Time.now.utc.iso8601

    @db.execute(
      <<~SQL,
        UPDATE jobs
        SET status = 'cancelled',
            result = ?,
            last_error = NULL,
            finished_at = ?,
            updated_at = ?
        WHERE id = ?
      SQL
      [reason, now, now, job_id]
    )

    log_event(job_id, "cancelled", "Job cancelado", reason)

    { ok: true, job_id: job_id.to_i, status: "cancelled", reason: reason }
  end

  private

  def counts
    {
      queued: count("queued"),
      running: count("running"),
      done: count("done"),
      failed: count("failed"),
      cancelled: count("cancelled"),
      stuck: stuck_jobs.size
    }
  end

  def count(status)
    @db.get_first_value("SELECT COUNT(*) FROM jobs WHERE status = ?", [status]).to_i
  rescue
    0
  end

  def stuck_jobs
    rows(
      <<~SQL
        SELECT *
        FROM jobs
        WHERE status IN ('queued', 'running')
          AND datetime(updated_at) <= datetime('now', '-15 minutes')
        ORDER BY priority DESC, id ASC
        LIMIT 20
      SQL
    )
  end

  def latest_jobs(limit:)
    rows(
      "SELECT * FROM jobs ORDER BY id DESC LIMIT ?",
      [limit]
    )
  end

  def latest_events(limit:)
    rows(
      "SELECT * FROM job_events ORDER BY id DESC LIMIT ?",
      [limit]
    )
  rescue
    []
  end

  def log_event(job_id, event_type, title, detail)
    @db.execute(
      <<~SQL,
        INSERT INTO job_events
        (
          job_id,
          event_type,
          title,
          detail,
          created_at
        )
        VALUES (?, ?, ?, ?, ?)
      SQL
      [job_id, event_type, title, detail, Time.now.utc.iso8601]
    )
  rescue
    nil
  end

  def row(sql, params = [])
    clean(@db.get_first_row(sql, params))
  end

  def rows(sql, params = [])
    @db.execute(sql, params).map { |r| clean(r) }
  end

  def clean(row)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
