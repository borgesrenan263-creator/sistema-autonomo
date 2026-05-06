require "time"

class OpsMonitoringEngine
  STALE_SECONDS = 180
  STUCK_JOB_SECONDS = 600

  def initialize(db)
    @db = db
  end

  def snapshot
    {
      generated_at: Time.now.iso8601,
      system: system_status,
      database: database_status,
      heartbeats: heartbeat_status,
      jobs: jobs_status,
      integrations: integrations_status,
      revenue_autopilot: revenue_autopilot_status,
      alerts: alerts
    }
  end

  private

  def system_status
    {
      app: "sistema-autonomo",
      env: ENV["APP_ENV"].to_s.empty? ? ENV["RACK_ENV"].to_s : ENV["APP_ENV"].to_s,
      ruby: RUBY_VERSION,
      time: Time.now.iso8601
    }
  end

  def database_status
    begin
      if DB.respond_to?(:test_connection)
        DB.test_connection
      elsif DB.respond_to?(:get_first_value)
        DB.get_first_value("SELECT 1")
      elsif DB.respond_to?(:execute)
        DB.execute("SELECT 1")
      else
        raise "DB adapter não suportado para healthcheck"
      end

      {
        ok: true,
        adapter: defined?(DatabaseConfig) ? DatabaseConfig.adapter : DB.class.name
      }
    rescue => e
      {
        ok: false,
        error: "#{e.class}: #{e.message}"
      }
    end
  end

  def heartbeat_status
    rows = all("SELECT * FROM ops_heartbeats ORDER BY component ASC")

    rows.map do |row|
      age = seconds_since(row["last_seen_at"])

      row.merge(
        "age_seconds" => age,
        "fresh" => age && age <= STALE_SECONDS
      )
    end
  end

  def jobs_status
    jobs = all("SELECT * FROM jobs ORDER BY id DESC LIMIT 300")

    failed = jobs.select { |j| j["status"].to_s == "failed" }
    running = jobs.select { |j| j["status"].to_s == "running" }
    queued = jobs.select { |j| j["status"].to_s == "queued" }
    done = jobs.select { |j| j["status"].to_s == "done" }

    stuck = running.select do |job|
      age = seconds_since(job["locked_at"] || job["started_at"])
      age && age > STUCK_JOB_SECONDS
    end

    {
      total_sample: jobs.count,
      queued: queued.count,
      running: running.count,
      done: done.count,
      failed: failed.count,
      stuck: stuck.count,
      latest_failed: failed.first(10),
      latest_stuck: stuck.first(10),
      latest_jobs: jobs.first(20)
    }
  end

  def integrations_status
    {
      smtp: {
        dispatch_enabled: setting("CHANNEL_DISPATCH_ENABLED") == "true",
        provider: setting("EMAIL_PROVIDER"),
        host_configured: !setting("SMTP_HOST").empty?,
        user_configured: !setting("SMTP_USER").empty?,
        password_configured: !setting("SMTP_PASSWORD").empty?,
        from_configured: !setting("SMTP_FROM").empty?
      },
      pix_webhook: {
        secret_configured: valid_secret?(setting("PIX_WEBHOOK_SECRET"))
      },
      response_webhook: {
        secret_configured: valid_secret?(setting("RESPONSE_WEBHOOK_SECRET"))
      }
    }
  end

  def revenue_autopilot_status
    log_path = File.expand_path("storage/logs/revenue_autopilot.log", Dir.pwd)

    if File.exist?(log_path)
      lines = File.readlines(log_path).last(20)
      last_cycle = lines.reverse.find { |line| line.include?("REVENUE_AUTOPILOT_CYCLE_DONE") || line.include?("REVENUE_AUTOPILOT_CYCLE_START") }

      {
        log_exists: true,
        last_event: last_cycle&.strip,
        log_path: log_path
      }
    else
      {
        log_exists: false,
        last_event: nil,
        log_path: log_path
      }
    end
  end

  def alerts
    list = []

    db = database_status
    list << "Database not ready: #{db[:error]}" unless db[:ok]

    heartbeat_status.each do |hb|
      unless hb["fresh"]
        list << "Heartbeat stale: #{hb["component"]} last_seen_at=#{hb["last_seen_at"]}"
      end
    end

    jobs = jobs_status
    list << "#{jobs[:failed]} job(s) failed." if jobs[:failed] > 0
    list << "#{jobs[:stuck]} job(s) stuck." if jobs[:stuck] > 0

    integrations = integrations_status

    if integrations[:smtp][:dispatch_enabled] && integrations[:smtp][:provider] == "smtp"
      unless integrations[:smtp][:host_configured] && integrations[:smtp][:user_configured] && integrations[:smtp][:password_configured]
        list << "SMTP dispatch enabled but SMTP config incomplete."
      end
    end

    list << "PIX_WEBHOOK_SECRET missing or unsafe." unless integrations[:pix_webhook][:secret_configured]
    list << "RESPONSE_WEBHOOK_SECRET missing or unsafe." unless integrations[:response_webhook][:secret_configured]

    list
  end

  def valid_secret?(value)
    v = value.to_s.strip
    return false if v.empty?
    return false if v == "trocar_em_producao"
    return false if v.start_with?("teste_")

    v.length >= 12
  end

  def setting(key)
    if defined?(AppSettings)
      AppSettings.get(key).to_s.strip
    else
      ENV[key].to_s.strip
    end
  end

  def seconds_since(value)
    return nil if value.to_s.empty?

    (Time.now - Time.parse(value.to_s)).round
  rescue
    nil
  end

  def all(sql, params = [])
    @db.execute(sql, params).map { |row| row.reject { |k, _| k.is_a?(Integer) } }
  end
end
