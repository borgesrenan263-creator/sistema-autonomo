# frozen_string_literal: true

require "json"
require "time"

class AutopilotDailyLoopEngine
  STEPS = [
    ["followup_scan", "Escanear follow-ups"],
    ["followup_run_due", "Processar follow-ups vencidos"],
    ["concierge_executor", "Executar decisões do Concierge"],
    ["dispatch_autopilot", "Processar dispatch seguro"],
    ["heartbeat", "Atualizar heartbeat operacional"]
  ].freeze

  def initialize(db)
    @db = db
  end

  def snapshot
    {
      generated_at: now,
      latest_run: latest_run,
      latest_events: latest_events,
      counts: {
        runs: count("autopilot_daily_loop_runs"),
        events: count("autopilot_daily_loop_events"),
        running: count_where("autopilot_daily_loop_runs", "status = 'running'"),
        done: count_where("autopilot_daily_loop_runs", "status = 'done'"),
        failed: count_where("autopilot_daily_loop_runs", "status = 'failed'")
      },
      current_state: current_state
    }
  end

  def run!(trigger_source: "manual")
    started_at = now
    before = current_state

    run_id = create_run(trigger_source, started_at, before)

    steps_ok = 0
    steps_failed = 0

    STEPS.each do |step_key, step_title|
      result = run_step(run_id, step_key, step_title)
      if result[:ok]
        steps_ok += 1
      else
        steps_failed += 1
      end
    end

    after = current_state
    status = steps_failed.zero? ? "done" : "partial"

    finish_run(run_id, status, started_at, before, after, steps_ok, steps_failed)

    one("SELECT * FROM autopilot_daily_loop_runs WHERE id = ?", [run_id])
  rescue => e
    if run_id
      execute(
        "UPDATE autopilot_daily_loop_runs SET status = ?, error = ?, finished_at = ?, updated_at = ? WHERE id = ?",
        ["failed", "#{e.class}: #{e.message}", now, now, run_id]
      )
    end

    raise
  end

  private

  def run_step(run_id, step_key, step_title)
    started_at = now

    event_id = create_event(run_id, step_key, step_title, "running", "Iniciando", nil, started_at)

    detail = case step_key
             when "followup_scan"
               call_followup_scan
             when "followup_run_due"
               call_followup_run_due
             when "concierge_executor"
               call_concierge_executor
             when "dispatch_autopilot"
               call_dispatch_autopilot
             when "heartbeat"
               update_heartbeat
             else
               "Step desconhecido"
             end

    finish_event(event_id, "done", detail, nil, started_at)

    { ok: true, detail: detail }
  rescue => e
    finish_event(event_id, "failed", nil, "#{e.class}: #{e.message}", started_at) if event_id
    { ok: false, error: "#{e.class}: #{e.message}" }
  end

  def call_followup_scan
    return "FollowupAutopilotEngine não encontrado" unless defined?(FollowupAutopilotEngine)

    engine = build_engine(FollowupAutopilotEngine)
    result = call_first_available(engine, [:scan, :scan!, :scan_candidates, :run_scan])

    "Follow-up scan executado: #{safe_inspect(result)}"
  end

  def call_followup_run_due
    return "FollowupAutopilotEngine não encontrado" unless defined?(FollowupAutopilotEngine)

    engine = build_engine(FollowupAutopilotEngine)
    result = call_first_available(engine, [:run_due, :run_due!, :process_due, :run_pending])

    "Follow-ups vencidos processados: #{safe_inspect(result)}"
  end

  def call_concierge_executor
    return "ConciergeDecisionExecutor não encontrado" unless defined?(ConciergeDecisionExecutor)

    engine = build_engine(ConciergeDecisionExecutor)
    result = if engine.respond_to?(:run_batch)
               engine.run_batch(20)
             else
               call_first_available(engine, [:run, :run!])
             end

    "Concierge executor executado: #{safe_inspect(result)}"
  end

  def call_dispatch_autopilot
    return "DispatchAutopilotEngine não encontrado" unless defined?(DispatchAutopilotEngine)

    engine = build_engine(DispatchAutopilotEngine)
    result = call_first_available(engine, [:run, :run!, :run_batch, :process_queue])

    "Dispatch autopilot executado: #{safe_inspect(result)}"
  end

  def update_heartbeat
    return "Tabela ops_heartbeats não existe" unless table_exists?("ops_heartbeats")

    current = one("SELECT * FROM ops_heartbeats WHERE component = ? LIMIT 1", ["autopilot_daily_loop"])
    timestamp = now

    if current
      execute(
        "UPDATE ops_heartbeats SET status = ?, detail = ?, metadata = ?, last_seen_at = ?, updated_at = ? WHERE component = ?",
        ["ok", "daily_loop_done", "{}", timestamp, timestamp, "autopilot_daily_loop"]
      )
    else
      execute(
        "INSERT INTO ops_heartbeats (component, status, detail, metadata, last_seen_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        ["autopilot_daily_loop", "ok", "daily_loop_done", "{}", timestamp, timestamp, timestamp]
      )
    end

    "Heartbeat autopilot_daily_loop atualizado"
  end

  def build_engine(klass)
    klass.new(@db)
  rescue ArgumentError
    klass.new
  end

  def call_first_available(engine, methods)
    method_name = methods.find { |name| engine.respond_to?(name) }
    return "Nenhum método compatível encontrado em #{engine.class}" unless method_name

    engine.public_send(method_name)
  end

  def create_run(trigger_source, started_at, before)
    execute(
      <<~SQL,
        INSERT INTO autopilot_daily_loop_runs
        (
          trigger_source, status, started_at,
          steps_total, steps_ok, steps_failed,
          followups_before, decisions_pending_before, dispatch_runs_before,
          revenue_before, pending_before,
          created_at, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        trigger_source,
        "running",
        started_at,
        STEPS.size,
        0,
        0,
        before[:followups_total],
        before[:decisions_pending],
        before[:dispatch_runs],
        before[:revenue_paid],
        before[:revenue_pending],
        started_at,
        started_at
      ]
    )

    last_insert_id
  end

  def finish_run(run_id, status, started_at, before, after, steps_ok, steps_failed)
    finished_at = now
    duration = duration_seconds(started_at, finished_at)

    followups_created = [after[:followups_total] - before[:followups_total], 0].max
    followups_processed = [after[:followups_processed] - before[:followups_processed], 0].max
    decisions_executed = [before[:decisions_pending] - after[:decisions_pending], 0].max

    dispatch_sent = [after[:dispatch_sent] - before[:dispatch_sent], 0].max
    dispatch_manual = [after[:dispatch_manual] - before[:dispatch_manual], 0].max
    dispatch_blocked = [after[:dispatch_blocked] - before[:dispatch_blocked], 0].max

    summary = [
      "status=#{status}",
      "steps_ok=#{steps_ok}",
      "steps_failed=#{steps_failed}",
      "followups_created=#{followups_created}",
      "followups_processed=#{followups_processed}",
      "decisions_executed=#{decisions_executed}",
      "dispatch_sent=#{dispatch_sent}",
      "dispatch_manual=#{dispatch_manual}",
      "dispatch_blocked=#{dispatch_blocked}",
      "revenue_delta=#{after[:revenue_paid] - before[:revenue_paid]}"
    ].join(" ")

    execute(
      <<~SQL,
        UPDATE autopilot_daily_loop_runs
        SET status = ?,
            finished_at = ?,
            duration_seconds = ?,
            steps_ok = ?,
            steps_failed = ?,
            followups_after = ?,
            followups_created = ?,
            followups_processed = ?,
            decisions_pending_after = ?,
            decisions_executed = ?,
            dispatch_runs_after = ?,
            dispatch_sent = ?,
            dispatch_manual = ?,
            dispatch_blocked = ?,
            revenue_after = ?,
            pending_after = ?,
            summary = ?,
            updated_at = ?
        WHERE id = ?
      SQL
      [
        status,
        finished_at,
        duration,
        steps_ok,
        steps_failed,
        after[:followups_total],
        followups_created,
        followups_processed,
        after[:decisions_pending],
        decisions_executed,
        after[:dispatch_runs],
        dispatch_sent,
        dispatch_manual,
        dispatch_blocked,
        after[:revenue_paid],
        after[:revenue_pending],
        summary,
        finished_at,
        run_id
      ]
    )
  end

  def create_event(run_id, step_key, step_title, status, detail, error, started_at)
    execute(
      <<~SQL,
        INSERT INTO autopilot_daily_loop_events
        (run_id, step_key, step_title, status, detail, error, started_at, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [run_id, step_key, step_title, status, detail, error, started_at, started_at]
    )

    last_insert_id
  end

  def finish_event(event_id, status, detail, error, started_at)
    finished_at = now

    execute(
      <<~SQL,
        UPDATE autopilot_daily_loop_events
        SET status = ?, detail = ?, error = ?, finished_at = ?, duration_seconds = ?
        WHERE id = ?
      SQL
      [status, detail, error, finished_at, duration_seconds(started_at, finished_at), event_id]
    )
  end

  def current_state
    {
      followups_total: count("followup_tasks"),
      followups_processed: count_where("followup_tasks", "status IN ('sent','done','lost')"),
      decisions_pending: count_where("concierge_decisions", "execution_status IS NULL OR execution_status = 'pending'"),
      dispatch_runs: count("dispatch_autopilot_runs"),
      dispatch_sent: count_where("dispatch_autopilot_events", "status = 'sent' OR event_type = 'sent'"),
      dispatch_manual: count_where("dispatch_autopilot_events", "status = 'manual' OR event_type = 'manual'"),
      dispatch_blocked: count_where("dispatch_autopilot_events", "status = 'blocked'"),
      revenue_paid: money_sum("payments", "amount", "status = 'paid'"),
      revenue_pending: money_sum("payments", "amount", "status = 'pending'")
    }
  end

  def latest_run
    return nil unless table_exists?("autopilot_daily_loop_runs")

    one("SELECT * FROM autopilot_daily_loop_runs ORDER BY id DESC LIMIT 1")
  end

  def latest_events
    return [] unless table_exists?("autopilot_daily_loop_events")

    execute("SELECT * FROM autopilot_daily_loop_events ORDER BY id DESC LIMIT 20")
  end

  def table_exists?(table_name)
    row = one(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
      [table_name]
    )

    !row.nil?
  rescue
    false
  end

  def count(table_name)
    return 0 unless table_exists?(table_name)

    row = one("SELECT COUNT(*) AS total FROM #{table_name}")
    integer_value(row, "total")
  rescue
    0
  end

  def count_where(table_name, where_sql)
    return 0 unless table_exists?(table_name)

    row = one("SELECT COUNT(*) AS total FROM #{table_name} WHERE #{where_sql}")
    integer_value(row, "total")
  rescue
    0
  end

  def money_sum(table_name, column_name, where_sql)
    return 0.0 unless table_exists?(table_name)

    row = one("SELECT COALESCE(SUM(#{column_name}), 0) AS total FROM #{table_name} WHERE #{where_sql}")
    float_value(row, "total")
  rescue
    0.0
  end

  def execute(sql, params = [])
    @db.execute(sql, params)
  end

  def one(sql, params = [])
    if @db.respond_to?(:get_first_row)
      @db.get_first_row(sql, params)
    else
      execute(sql, params).first
    end
  end

  def last_insert_id
    if @db.respond_to?(:last_insert_row_id)
      @db.last_insert_row_id
    else
      row = one("SELECT last_insert_rowid() AS id")
      integer_value(row, "id")
    end
  end

  def integer_value(row, key)
    return 0 unless row

    value = row[key] || row[key.to_sym] || row[0]
    value.to_i
  end

  def float_value(row, key)
    return 0.0 unless row

    value = row[key] || row[key.to_sym] || row[0]
    value.to_f
  end

  def duration_seconds(started_at, finished_at)
    (Time.parse(finished_at) - Time.parse(started_at)).to_i
  rescue
    0
  end

  def now
    Time.now.utc.iso8601
  end

  def safe_inspect(value)
    text = value.inspect
    text.length > 500 ? "#{text[0, 500]}..." : text
  rescue
    "-"
  end
end
