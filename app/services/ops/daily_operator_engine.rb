require "date"
require "time"

class DailyOperatorEngine
  def initialize(db)
    @db = db
  end

  def snapshot
    today = Date.today.to_s

    financial = safe_financial_snapshot
    monitoring = safe_monitoring_snapshot

    {
      generated_at: Time.now.iso8601,
      today: today,
      system: system_summary(monitoring),
      money: money_summary(financial, today),
      payments: payments_summary,
      responses: responses_summary,
      opportunities: opportunities_summary,
      deliveries: deliveries_summary,
      jobs: jobs_summary(monitoring),
      monitoring: monitoring,
      autopilot_daily_loop: autopilot_daily_loop_snapshot,
      next_action: next_action(financial, monitoring),
      checklist: checklist(financial, monitoring)
    }
  end

  private

  def safe_financial_snapshot
    if defined?(FinancialMetricsEngine)
      FinancialMetricsEngine.new(@db).snapshot
    else
      {}
    end
  rescue => e
    { error: "#{e.class}: #{e.message}" }
  end

  def safe_monitoring_snapshot
    if defined?(OpsMonitoringEngine)
      OpsMonitoringEngine.new(@db).snapshot
    else
      {}
    end
  rescue => e
    { error: "#{e.class}: #{e.message}" }
  end

  def system_summary(monitoring)
    database_ok = dig_hash(monitoring, :database, :ok)
    alerts = monitoring[:alerts] || []

    {
      database_ok: database_ok,
      alerts_count: alerts.count,
      alerts: alerts.first(6),
      uptime_ok: database_ok && alerts.count == 0
    }
  end

  def money_summary(financial, today)
    totals = financial[:totals] || {}
    revenue_by_day = financial[:revenue_by_day] || {}

    {
      revenue_today: revenue_by_day[today] || 0,
      revenue_paid: totals[:revenue_paid] || 0,
      revenue_pending: totals[:revenue_pending] || 0,
      average_ticket: totals[:average_ticket] || 0,
      paid_count: totals[:paid_count] || 0,
      pending_count: totals[:pending_count] || 0,
      conversion_payment_rate: totals[:conversion_payment_rate] || 0
    }
  end

  def payments_summary
    paid = all(
      <<~SQL
        SELECT *
        FROM payments
        WHERE status = 'paid'
        ORDER BY paid_at DESC, id DESC
        LIMIT 5
      SQL
    )

    pending = all(
      <<~SQL
        SELECT *
        FROM payments
        WHERE status = 'pending'
        ORDER BY created_at DESC, id DESC
        LIMIT 10
      SQL
    )

    {
      latest_paid: paid,
      pending: pending,
      pending_count: pending.count
    }
  rescue
    { latest_paid: [], pending: [], pending_count: 0 }
  end

  def responses_summary
    events = table_exists?("response_inbox_events") ? all(
      <<~SQL
        SELECT *
        FROM response_inbox_events
        ORDER BY id DESC
        LIMIT 10
      SQL
    ) : []

    interested = events.select { |e| e["response_status"].to_s == "interested" }

    {
      latest: events,
      interested_count: interested.count,
      unprocessed_count: events.count { |e| e["processed"].to_s != "1" }
    }
  rescue
    { latest: [], interested_count: 0, unprocessed_count: 0 }
  end

  def opportunities_summary
    tasks = all(
      <<~SQL
        SELECT id, title, status, quality_status, url, created_at, updated_at
        FROM tasks
        ORDER BY id DESC
        LIMIT 15
      SQL
    )

    monetizable = tasks.select { |t| t["quality_status"].to_s == "monetizable" }

    {
      latest: tasks,
      latest_count: tasks.count,
      monetizable_count: monetizable.count
    }
  rescue
    { latest: [], latest_count: 0, monetizable_count: 0 }
  end

  def deliveries_summary
    rows = all(
      <<~SQL
        SELECT id, task_id, validation_status, validation_score, validated_at, created_at
        FROM deliveries
        ORDER BY id DESC
        LIMIT 20
      SQL
    )

    sandbox = table_exists?("validation_sandbox_runs") ? all(
      <<~SQL
        SELECT *
        FROM validation_sandbox_runs
        ORDER BY id DESC
        LIMIT 10
      SQL
    ) : []

    {
      latest: rows,
      validated_count: rows.count { |d| d["validation_status"].to_s == "validated" },
      manual_review_count: rows.count { |d| d["validation_status"].to_s == "manual_review" },
      sandbox_passed_count: sandbox.count { |s| s["status"].to_s == "passed" },
      sandbox_latest: sandbox
    }
  rescue
    { latest: [], validated_count: 0, manual_review_count: 0, sandbox_passed_count: 0, sandbox_latest: [] }
  end

  def jobs_summary(monitoring)
    jobs = monitoring[:jobs] || {}

    {
      failed: jobs[:failed] || 0,
      stuck: jobs[:stuck] || 0,
      queued: jobs[:queued] || 0,
      running: jobs[:running] || 0,
      latest_jobs: jobs[:latest_jobs] || []
    }
  end

  def next_action(financial, monitoring)
    alerts = monitoring[:alerts] || []
    jobs = monitoring[:jobs] || {}
    totals = financial[:totals] || {}

    return action("Resolver alerta operacional", alerts.first, "/ops/monitoring") if alerts.any?
    return action("Reprocessar jobs falhados", "#{jobs[:failed]} job(s) falhados.", "/jobs") if jobs[:failed].to_i > 0
    return action("Verificar jobs travados", "#{jobs[:stuck]} job(s) travados.", "/jobs") if jobs[:stuck].to_i > 0
    return action("Cobrar pagamentos pendentes", "#{totals[:pending_count]} pagamento(s) pendente(s).", "/finance/metrics") if totals[:pending_count].to_i > 0

    responses = responses_summary
    return action("Responder contatos interessados", "#{responses[:interested_count]} interessado(s) recentes.", "/responses/inbox") if responses[:interested_count].to_i > 0

    deliveries = deliveries_summary
    return action("Revisar entregas em manual_review", "#{deliveries[:manual_review_count]} entrega(s) em revisão.", "/validation") if deliveries[:manual_review_count].to_i > 0

    action("Rodar ciclo operacional do dia", "Sistema limpo. Rode o ciclo para buscar novas oportunidades.", "/revenue-autopilot")
  end

  def checklist(financial, monitoring)
    totals = financial[:totals] || {}
    jobs = monitoring[:jobs] || {}

    [
      {
        label: "Sistema online e banco OK",
        done: dig_hash(monitoring, :database, :ok) == true
      },
      {
        label: "Sem jobs falhados",
        done: jobs[:failed].to_i == 0
      },
      {
        label: "Sem jobs travados",
        done: jobs[:stuck].to_i == 0
      },
      {
        label: "Sem pagamentos pendentes",
        done: totals[:pending_count].to_i == 0
      },
      {
        label: "Worker com heartbeat recente",
        done: worker_fresh?(monitoring)
      }
    ]
  end

  def worker_fresh?(monitoring)
    heartbeats = monitoring[:heartbeats] || []
    job_worker = heartbeats.find { |h| h["component"].to_s == "job_worker" }
    job_worker && job_worker["fresh"] == true
  end

  def action(title, detail, link)
    {
      title: title,
      detail: detail,
      link: link
    }
  end

  def table_exists?(name)
    row = @db.get_first_row(
      "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
      [name]
    )
    !!row
  rescue
    false
  end

  def dig_hash(hash, *keys)
    keys.reduce(hash) do |h, key|
      h.respond_to?(:[]) ? h[key] : nil
    end
  end

  def all(sql, params = [])
    @db.execute(sql, params).map { |row| row.reject { |k, _| k.is_a?(Integer) } }
  end

  def autopilot_daily_loop_snapshot
    return empty_autopilot_daily_loop_snapshot unless table_exists?("autopilot_daily_loop_runs")

    latest = first_row("SELECT * FROM autopilot_daily_loop_runs ORDER BY id DESC LIMIT 1")
    events = if table_exists?("autopilot_daily_loop_events")
               execute("SELECT * FROM autopilot_daily_loop_events ORDER BY id DESC LIMIT 5")
             else
               []
             end

    {
      "latest" => latest,
      :latest => latest,
      "events" => events,
      :events => events,
      "counts" => {
        total: count_table("autopilot_daily_loop_runs"),
        done: count_where("autopilot_daily_loop_runs", "status = 'done'"),
        partial: count_where("autopilot_daily_loop_runs", "status = 'partial'"),
        failed: count_where("autopilot_daily_loop_runs", "status = 'failed'")
      },
      "health" => autopilot_daily_loop_health(latest),
      :health => autopilot_daily_loop_health(latest)
    }
  rescue => e
    empty_autopilot_daily_loop_snapshot.merge(
      error: "#{e.class}: #{e.message}",
      health: "error"
    )
  end

  def empty_autopilot_daily_loop_snapshot
    {
      latest: nil,
      events: [],
      "counts" => {
        total: 0,
        done: 0,
        partial: 0,
        failed: 0
      },
      health: "missing"
    }
  end

  def autopilot_daily_loop_health(latest)
    return "missing" unless latest

    status = latest["status"].to_s
    failed = latest["steps_failed"].to_i

    return "ok" if status == "done" && failed.zero?
    return "attention" if status == "partial"
    return "error" if status == "failed"

    "attention"
  end

end
