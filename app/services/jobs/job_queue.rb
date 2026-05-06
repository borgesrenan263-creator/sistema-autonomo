require "json"
require "time"

class JobQueue
  def initialize(db)
    @db = db
  end

  def enqueue(job_type:, payload: {}, priority: 50, run_at: nil, max_attempts: 3)
    now = Time.now.iso8601
    run_at ||= now

    @db.execute(
      <<~SQL,
        INSERT INTO jobs
        (
          job_type,
          status,
          priority,
          attempts,
          max_attempts,
          payload,
          run_at,
          created_at,
          updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        job_type,
        "queued",
        priority,
        0,
        max_attempts,
        JSON.generate(payload || {}),
        run_at,
        now,
        now
      ]
    )

    job_id = @db.last_insert_row_id

    event(
      job_id: job_id,
      event_type: "queued",
      title: "Job enfileirado",
      detail: job_type
    )

    find(job_id)
  end

  def find(id)
    clean(@db.get_first_row("SELECT * FROM jobs WHERE id = ?", [id]))
  end

  def next_job
    clean(
      @db.get_first_row(
        <<~SQL
          SELECT *
          FROM jobs
          WHERE status = 'queued'
            AND datetime(run_at) <= datetime('now')
          ORDER BY priority DESC, id ASC
          LIMIT 1
        SQL
      )
    )
  end

  def lock(job)
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        UPDATE jobs
        SET status = 'running',
            locked_at = ?,
            started_at = COALESCE(started_at, ?),
            updated_at = ?
        WHERE id = ?
          AND status = 'queued'
      SQL
      [now, now, now, job["id"]]
    )

    find(job["id"])
  end

  def mark_done(job_id, result)
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        UPDATE jobs
        SET status = 'done',
            result = ?,
            last_error = NULL,
            finished_at = ?,
            updated_at = ?
        WHERE id = ?
      SQL
      [result.to_s, now, now, job_id]
    )

    event(
      job_id: job_id,
      event_type: "done",
      title: "Job concluído",
      detail: result.to_s
    )
  end

  def mark_failed(job_id, error)
    job = find(job_id)
    attempts = job["attempts"].to_i + 1
    max_attempts = job["max_attempts"].to_i
    now = Time.now.iso8601

    if attempts >= max_attempts
      @db.execute(
        <<~SQL,
          UPDATE jobs
          SET status = 'failed',
              attempts = ?,
              last_error = ?,
              finished_at = ?,
              updated_at = ?
          WHERE id = ?
        SQL
        [attempts, error.to_s, now, now, job_id]
      )

      event(
        job_id: job_id,
        event_type: "failed",
        title: "Job falhou definitivamente",
        detail: error.to_s
      )
    else
      retry_at = (Time.now + (attempts * 60)).iso8601

      @db.execute(
        <<~SQL,
          UPDATE jobs
          SET status = 'queued',
              attempts = ?,
              last_error = ?,
              locked_at = NULL,
              run_at = ?,
              updated_at = ?
          WHERE id = ?
        SQL
        [attempts, error.to_s, retry_at, now, job_id]
      )

      event(
        job_id: job_id,
        event_type: "retry",
        title: "Job reagendado",
        detail: "attempts=#{attempts}; retry_at=#{retry_at}; error=#{error}"
      )
    end
  end

  def event(job_id:, event_type:, title:, detail: nil)
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
      [job_id, event_type, title, detail, Time.now.iso8601]
    )
  end

  private

  def clean(row)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
