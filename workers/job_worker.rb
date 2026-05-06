require "time"

require_relative "../config/database"
require_relative "../config/app_settings"
require_relative "../app/core/database_helpers"

require_relative "../scripts/backup_manager"

require_relative "../app/services/jobs/job_queue"
require_relative "../app/services/jobs/job_runner"
require_relative "../app/services/ops/ops_heartbeat"

require_relative "../app/services/notifications/system_notifier"
require_relative "../app/services/automation/automation_event_logger"
require_relative "../app/services/automation/automation_engine"
require_relative "../app/services/concierge/concierge_value_filter"
require_relative "../app/services/concierge/concierge_engine"
require_relative "../app/services/concierge/concierge_autopilot"
require_relative "../app/services/channels/channel_dispatch_engine"
require_relative "../app/services/observability/observability_engine"
require_relative "../app/services/validation/validation_engine"

DB = DatabaseConfig.connect unless defined?(DB)

interval = (ENV["JOB_WORKER_INTERVAL_SECONDS"] || "60").to_i
interval = 60 if interval <= 0

puts "[#{Time.now.iso8601}] JOB_WORKER_BOOT interval=#{interval}s"

runner = JobRunner.new(DB)
heartbeat = OpsHeartbeat.new(DB)

if ARGV.include?("--once")
  result = runner.run_next
  puts "[#{Time.now.iso8601}] JOB_WORKER_ONCE result=#{result.inspect}"
  exit 0
end

loop do
  begin
    heartbeat.beat(component: "job_worker", status: "ok", detail: "loop_start")
    result = runner.run_next

    if result
      heartbeat.beat(component: "job_worker", status: "ok", detail: "done: #{result}")
      puts "[#{Time.now.iso8601}] JOB_WORKER_DONE #{result}"
    else
      heartbeat.beat(component: "job_worker", status: "idle", detail: "no_jobs")
      puts "[#{Time.now.iso8601}] JOB_WORKER_IDLE"
    end
  rescue => e
    heartbeat.beat(component: "job_worker", status: "error", detail: "#{e.class}: #{e.message}")
    puts "[#{Time.now.iso8601}] JOB_WORKER_ERROR #{e.class}: #{e.message}"
  end

  sleep interval
end
