require "time"
require "json"
require "date"

class WorkSessionEngine
  def initialize(db)
    @db = db
  end

  def dashboard
    active = active_session
    latest = latest_sessions

    {
      generated_at: Time.now.iso8601,
      active_session: active && enrich_session(active),
      latest_sessions: latest.map { |s| enrich_session(s) },
      today_summary: today_summary,
      checklist: checklist
    }
  end

  def start_session
    existing = active_session
    return existing if existing

    now = Time.now.iso8601
    revenue = current_revenue_paid

    @db.execute(
      <<~SQL,
        INSERT INTO work_sessions
        (
          status,
          started_at,
          title,
          revenue_start,
          revenue_end,
          revenue_delta,
          actions_count,
          created_at,
          updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        "active",
        now,
        "Sessão de trabalho — #{Date.today}",
        revenue,
        revenue,
        0,
        0,
        now,
        now
      ]
    )

    session = one("SELECT * FROM work_sessions WHERE id = ?", [@db.last_insert_row_id])

    record_event(
      session["id"],
      "session_started",
      "Sessão iniciada",
      "Sessão de trabalho iniciada.",
      "/work-session"
    )

    session
  end

  def end_session(notes: nil)
    session = active_session
    raise "Nenhuma sessão ativa" unless session

    now = Time.now.iso8601
    revenue_end = current_revenue_paid
    revenue_delta = revenue_end.to_f - session["revenue_start"].to_f
    actions_count = scalar("SELECT COUNT(*) FROM work_session_events WHERE work_session_id = ?", [session["id"]])

    @db.execute(
      <<~SQL,
        UPDATE work_sessions
        SET status = ?,
            ended_at = ?,
            notes = ?,
            revenue_end = ?,
            revenue_delta = ?,
            actions_count = ?,
            updated_at = ?
        WHERE id = ?
      SQL
      [
        "closed",
        now,
        notes,
        revenue_end,
        revenue_delta,
        actions_count,
        now,
        session["id"]
      ]
    )

    record_event(
      session["id"],
      "session_ended",
      "Sessão encerrada",
      "Receita durante a sessão: R$ #{format_money(revenue_delta)}",
      "/work-session"
    )

    one("SELECT * FROM work_sessions WHERE id = ?", [session["id"]])
  end

  def log_event(event_type:, title:, body: nil, link: nil, metadata: {})
    session = active_session || start_session

    record_event(
      session["id"],
      event_type,
      title,
      body,
      link,
      metadata
    )
  end

  def run_daily_cycle
    session = active_session || start_session

    if defined?(JobRunner)
      JobRunner.new(@db).seed_revenue_cycle
    end

    record_event(
      session["id"],
      "daily_cycle_seeded",
      "Ciclo operacional enfileirado",
      "Jobs do ciclo diário foram criados/enfileirados.",
      "/jobs"
    )

    true
  end

  private

  def enrich_session(session)
    events = all(
      "SELECT * FROM work_session_events WHERE work_session_id = ? ORDER BY id DESC LIMIT 100",
      [session["id"]]
    )

    session.merge(
      "events" => events,
      "duration_minutes" => duration_minutes(session),
      "summary" => session_summary(session, events)
    )
  end

  def session_summary(session, events)
    {
      events_count: events.count,
      revenue_delta: session["revenue_delta"].to_f,
      responses_actions: events.count { |e| e["event_type"].to_s.include?("response") },
      charges: events.count { |e| e["event_type"].to_s.include?("charge") || e["event_type"].to_s.include?("payment") },
      jobs: events.count { |e| e["event_type"].to_s.include?("job") || e["event_type"].to_s.include?("cycle") }
    }
  end

  def today_summary
    today = Date.today.to_s

    sessions = all(
      "SELECT * FROM work_sessions WHERE started_at LIKE ? ORDER BY id DESC",
      ["#{today}%"]
    )

    {
      sessions_count: sessions.count,
      active_count: sessions.count { |s| s["status"] == "active" },
      closed_count: sessions.count { |s| s["status"] == "closed" },
      revenue_delta: sessions.sum { |s| s["revenue_delta"].to_f },
      actions_count: sessions.sum { |s| s["actions_count"].to_i }
    }
  end

  def checklist
    active = active_session

    monitoring =
      if defined?(OpsMonitoringEngine)
        OpsMonitoringEngine.new(@db).snapshot
      else
        {}
      end

    command =
      if defined?(DailyOperatorEngine)
        DailyOperatorEngine.new(@db).snapshot
      else
        {}
      end

    [
      {
        label: "Sessão de trabalho iniciada",
        done: !!active
      },
      {
        label: "Sistema online e banco OK",
        done: monitoring.dig(:database, :ok) == true
      },
      {
        label: "Sem alertas operacionais",
        done: (monitoring[:alerts] || []).empty?
      },
      {
        label: "Sem jobs falhados/travados",
        done: monitoring.dig(:jobs, :failed).to_i == 0 && monitoring.dig(:jobs, :stuck).to_i == 0
      },
      {
        label: "Command Center revisado",
        done: command.dig(:system, :database_ok) == true
      }
    ]
  rescue
    []
  end

  def duration_minutes(session)
    start_time = parse_time(session["started_at"])
    end_time = parse_time(session["ended_at"]) || Time.now
    return 0 unless start_time

    ((end_time - start_time) / 60).round
  rescue
    0
  end

  def current_revenue_paid
    row = @db.get_first_row("SELECT COALESCE(SUM(amount), 0) AS total FROM payments WHERE status = 'paid'")
    if row.is_a?(Hash)
      row["total"].to_f
    else
      row[0].to_f
    end
  rescue
    0
  end

  def active_session
    one("SELECT * FROM work_sessions WHERE status = 'active' ORDER BY id DESC LIMIT 1")
  end

  def latest_sessions
    all("SELECT * FROM work_sessions ORDER BY id DESC LIMIT 20")
  end

  def record_event(session_id, event_type, title, body = nil, link = nil, metadata = {})
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        INSERT INTO work_session_events
        (
          work_session_id,
          event_type,
          title,
          body,
          link,
          metadata,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        session_id,
        event_type,
        title,
        body,
        link,
        JSON.generate(metadata || {}),
        now
      ]
    )

    @db.execute(
      "UPDATE work_sessions SET actions_count = actions_count + 1, updated_at = ? WHERE id = ?",
      [now, session_id]
    )
  end

  def parse_time(value)
    return nil if value.to_s.empty?
    Time.parse(value.to_s)
  rescue
    nil
  end

  def format_money(value)
    "%.2f" % value.to_f
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
