require "time"
require_relative "../config/database"
require_relative "../app/core/database_helpers"

require_relative "../app/services/notifications/system_notifier"
require_relative "../app/services/automation/automation_event_logger"
require_relative "../app/services/automation/automation_engine"
require_relative "../app/services/concierge/concierge_value_filter"
require_relative "../app/services/concierge/concierge_engine"
require_relative "../app/services/concierge/concierge_autopilot"

DB = DatabaseConfig.connect unless defined?(DB)

interval = (ENV["CONCIERGE_AUTOPILOT_INTERVAL_SECONDS"] || "60").to_i
interval = 60 if interval <= 0

puts "[#{Time.now.iso8601}] CONCIERGE_AUTOPILOT_BOOT interval=#{interval}s"

loop do
  begin
    puts "[#{Time.now.iso8601}] CONCIERGE_AUTOPILOT_RUN"
    ConciergeAutopilot.new(DB).run_once
    puts "[#{Time.now.iso8601}] CONCIERGE_AUTOPILOT_OK"
  rescue => e
    puts "[#{Time.now.iso8601}] CONCIERGE_AUTOPILOT_ERROR #{e.class}: #{e.message}"
  end

  sleep interval
end
