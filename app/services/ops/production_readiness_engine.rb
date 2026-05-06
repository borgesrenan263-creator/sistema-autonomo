require "time"

class ProductionReadinessEngine
  def initialize(db)
    @db = db
  end

  def snapshot
    checks = [
      check_database,
      check_env,
      check_worker_heartbeat,
      check_daily_loop,
      check_jobs,
      check_logs,
      check_backup,
      check_money_recovery,
      check_dispatch_safety
    ]

    {
      generated_at: Time.now.utc.iso8601,
      score: score(checks),
      status: overall_status(checks),
      checks: checks,
      blockers: checks.select { |c| c[:status] == "blocker" },
      warnings: checks.select { |c| c[:status] == "warning" },
      passed: checks.select { |c| c[:status] == "ok" }
    }
  end

  private

  def check_database
    @db.get_first_value("SELECT 1")

    ok(
      "database",
      "Banco conectado",
      "SQLite respondeu corretamente."
    )
  rescue => e
    blocker(
      "database",
      "Banco indisponível",
      "#{e.class}: #{e.message}"
    )
  end

  def check_env
    required = []
    recommended = [
      "SESSION_SECRET",
      "APP_ENV",
      "CHANNEL_DISPATCH_ENABLED",
      "CHANNEL_DAILY_LIMIT",
      "AUTOPILOT_DAILY_LOOP_INTERVAL_MINUTES"
    ]

    missing_required = required.select { |k| ENV[k].to_s.strip.empty? }
    missing_recommended = recommended.select { |k| ENV[k].to_s.strip.empty? }

    if missing_required.any?
      blocker(
        "env",
        "Variáveis obrigatórias ausentes",
        missing_required.join(", ")
      )
    elsif missing_recommended.any?
      warning(
        "env",
        "Variáveis recomendadas ausentes",
        missing_recommended.join(", ")
      )
    else
      ok(
        "env",
        "Variáveis principais configuradas",
        "Ambiente tem configurações mínimas para operação."
      )
    end
  end

  def check_worker_heartbeat
    return warning("worker", "Tabela de heartbeats ausente", "ops_heartbeats não existe.") unless table_exists?("ops_heartbeats")

    hb = row("SELECT * FROM ops_heartbeats WHERE component = 'job_worker' ORDER BY id DESC LIMIT 1")

    return blocker("worker", "Worker sem heartbeat", "Nenhum heartbeat do job_worker encontrado.") unless hb

    last_seen = Time.parse(hb["last_seen_at"].to_s) rescue nil
    return warning("worker", "Heartbeat inválido", "last_seen_at=#{hb["last_seen_at"]}") unless last_seen

    age = Time.now.utc - last_seen

    if age <= 180
      ok("worker", "Worker recente", "Último heartbeat há #{age.to_i}s.")
    elsif age <= 900
      warning("worker", "Worker possivelmente parado", "Último heartbeat há #{age.to_i}s.")
    else
      blocker("worker", "Worker parado", "Último heartbeat há #{age.to_i}s.")
    end
  end

  def check_daily_loop
    return warning("daily_loop", "Tabela Daily Loop ausente", "autopilot_daily_loop_runs não existe.") unless table_exists?("autopilot_daily_loop_runs")

    run = row("SELECT * FROM autopilot_daily_loop_runs ORDER BY id DESC LIMIT 1")

    return warning("daily_loop", "Daily Loop nunca executou", "Nenhum run encontrado.") unless run

    if run["status"].to_s == "done"
      ok("daily_loop", "Daily Loop saudável", "Último run ##{run["id"]} done com #{run["steps_ok"]}/#{run["steps_total"]} steps.")
    elsif run["status"].to_s == "partial"
      warning("daily_loop", "Daily Loop parcial", "Último run parcial: #{run["summary"]}")
    else
      blocker("daily_loop", "Daily Loop falhou", "Status=#{run["status"]}; error=#{run["error"]}")
    end
  end

  def check_jobs
    return warning("jobs", "Tabela jobs ausente", "jobs não existe.") unless table_exists?("jobs")

    failed = count_where("jobs", "status = 'failed'")
    running = count_where("jobs", "status = 'running'")
    queued = count_where("jobs", "status = 'queued'")

    if failed > 0
      warning("jobs", "Existem jobs falhados", "failed=#{failed}; running=#{running}; queued=#{queued}")
    else
      ok("jobs", "Fila sem falhas críticas", "failed=0; running=#{running}; queued=#{queued}")
    end
  end

  def check_logs
    log_path = File.join(Dir.pwd, "storage", "logs", "server.log")

    return warning("logs", "server.log ausente", log_path) unless File.exist?(log_path)

    size = File.size(log_path)

    if size > 0
      ok("logs", "Logs ativos", "server.log existe com #{size} bytes.")
    else
      warning("logs", "Log vazio", "server.log existe, mas está vazio.")
    end
  end

  def check_backup
    backup_log = File.join(Dir.pwd, "storage", "logs", "backup_manager.log")

    if File.exist?(backup_log)
      ok("backup", "Backup log encontrado", backup_log)
    else
      warning("backup", "Backup ainda não comprovado", "backup_manager.log não encontrado.")
    end
  end

  def check_money_recovery
    return warning("money_recovery", "Deals ausentes", "Tabela deals não existe.") unless table_exists?("deals")

    pipeline = money_sum("deals", "value", "status IN ('proposta_criada','interessado')")
    pending = table_exists?("payments") ? money_sum("payments", "amount", "status = 'pending'") : 0

    ok(
      "money_recovery",
      "Money Recovery disponível",
      "pipeline_aberto=#{pipeline}; pagamentos_pendentes=#{pending}"
    )
  end

  def check_dispatch_safety
    enabled = ENV["CHANNEL_DISPATCH_ENABLED"].to_s == "true"

    if enabled
      warning(
        "dispatch_safety",
        "Dispatch real ligado",
        "CHANNEL_DISPATCH_ENABLED=true. Confirmar limites, opt-out e política anti-spam."
      )
    else
      ok(
        "dispatch_safety",
        "Dispatch real desativado",
        "Modo seguro/manual ativo."
      )
    end
  end

  def score(checks)
    return 0 if checks.empty?

    ok_count = checks.count { |c| c[:status] == "ok" }
    warning_count = checks.count { |c| c[:status] == "warning" }
    blocker_count = checks.count { |c| c[:status] == "blocker" }

    raw = (ok_count * 100 + warning_count * 50 - blocker_count * 50).to_f / checks.size
    [[raw.round, 0].max, 100].min
  end

  def overall_status(checks)
    return "blocker" if checks.any? { |c| c[:status] == "blocker" }
    return "warning" if checks.any? { |c| c[:status] == "warning" }

    "ok"
  end

  def ok(key, title, detail)
    { key: key, status: "ok", title: title, detail: detail }
  end

  def warning(key, title, detail)
    { key: key, status: "warning", title: title, detail: detail }
  end

  def blocker(key, title, detail)
    { key: key, status: "blocker", title: title, detail: detail }
  end

  def table_exists?(name)
    !!@db.get_first_value("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [name])
  end

  def row(sql, params = [])
    clean(@db.get_first_row(sql, params))
  rescue
    nil
  end

  def count_where(table, where)
    @db.get_first_value("SELECT COUNT(*) FROM #{table} WHERE #{where}").to_i
  rescue
    0
  end

  def money_sum(table, column, where)
    @db.get_first_value("SELECT COALESCE(SUM(#{column}), 0) FROM #{table} WHERE #{where}").to_f
  rescue
    0.0
  end

  def clean(row)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
