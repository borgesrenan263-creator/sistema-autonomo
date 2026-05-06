require "json"
require "net/http"
require "uri"
require "time"
require_relative "../ops/autopilot_daily_loop_engine"

class JobRunner
  def initialize(db)
    @db = db
    @queue = JobQueue.new(db)
  end

  def run_next
    job = @queue.next_job
    return nil unless job

    locked = @queue.lock(job)
    return nil unless locked && locked["status"] == "running"

    begin
      result = perform(locked)
      @queue.mark_done(locked["id"], result)
      result
    rescue => e
      @queue.mark_failed(locked["id"], "#{e.class}: #{e.message}")
      raise e
    end
  end

  def run_batch(limit = 10)
    results = []

    limit.times do
      result = run_next
      break unless result

      results << result
    rescue => e
      results << "ERROR: #{e.class}: #{e.message}"
    end

    results
  end

  def seed_revenue_cycle
    queue_once("force_rescan", priority: 80)
    queue_once("concierge_autopilot", priority: 70)
    queue_once("channel_dispatch", priority: 60)
    queue_once("observability_scan", priority: 50)
    queue_once("validation_run", priority: 40)

    true
  end


  def schedule_autopilot_daily_loop_if_due(interval_minutes: nil)
    interval_minutes ||= ENV.fetch("AUTOPILOT_DAILY_LOOP_INTERVAL_MINUTES", "30").to_i
    interval_seconds = interval_minutes * 60

    existing = @db.get_first_row(
      "SELECT * FROM jobs WHERE job_type = ? AND status IN ('queued', 'running') LIMIT 1",
      ["autopilot_daily_loop"]
    )

    return { status: "skipped", reason: "already_queued_or_running", job_id: existing["id"] } if existing

    latest = @db.get_first_row(
      "SELECT * FROM autopilot_daily_loop_runs ORDER BY id DESC LIMIT 1"
    ) rescue nil

    if latest && latest["finished_at"]
      last_time = Time.parse(latest["finished_at"].to_s) rescue nil

      if last_time
        age_seconds = Time.now.utc - last_time

        if age_seconds < interval_seconds
          return {
            status: "skipped",
            reason: "recent_run",
            age_seconds: age_seconds.to_i,
            interval_seconds: interval_seconds
          }
        end
      end
    end

    job = @queue.enqueue(
      job_type: "autopilot_daily_loop",
      payload: { source: "scheduler" },
      priority: 90
    )

    {
      status: "queued",
      job_id: job["id"],
      interval_minutes: interval_minutes
    }
  end

  private

  def perform(job)
    payload = parse_payload(job["payload"])

    case job["job_type"]
    when "force_rescan"
      post_local("/force-rescan")
      "force_rescan done"

    when "concierge_autopilot"
      ConciergeAutopilot.new(@db).run_once
      "concierge_autopilot done"

    when "autopilot_daily_loop"
      AutopilotDailyLoopEngine.new(@db).run!(trigger_source: "job_worker")
      "autopilot_daily_loop done"

    when "channel_dispatch"
      ChannelDispatchEngine.new(@db).run_once
      "channel_dispatch done"

    when "observability_scan"
      ObservabilityEngine.new(@db).scan
      "observability_scan done"

    when "validation_run"
      ValidationEngine.new(@db).validate_latest
      "validation_run done"

    when "backup_run"
      BackupManager.new.run
      "backup_run done"

    when "self_repair"
      system("ruby scripts/self_repair.rb > storage/logs/self_repair_job.log 2>&1")
      "self_repair done"

    else
      raise "Tipo de job desconhecido: #{job["job_type"]}"
    end
  end


  def post_local(path)
    base_url = ENV["JOB_QUEUE_BASE_URL"] || "http://127.0.0.1:4567"
    uri = URI.join(base_url, path)

    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 5
    http.read_timeout = 60

    req = Net::HTTP::Post.new(uri)
    http.request(req)
  end

  def queue_once(job_type, priority:)
    existing = @db.get_first_row(
      "SELECT * FROM jobs WHERE job_type = ? AND status IN ('queued', 'running') LIMIT 1",
      [job_type]
    )

    return existing if existing

    @queue.enqueue(
      job_type: job_type,
      payload: {},
      priority: priority
    )
  end

  def parse_payload(payload)
    JSON.parse(payload.to_s.empty? ? "{}" : payload)
  rescue JSON::ParserError
    {}
  end

  def call_if_defined(constant_name)
    if Object.const_defined?(constant_name)
      yield
    else
      nil
    end
  end
end
