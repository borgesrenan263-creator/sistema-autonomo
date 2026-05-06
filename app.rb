require_relative "app/core/auth_guard"
require "sinatra"
require "json"
require "time"
require "fileutils"
require "csv"
require "sqlite3"

require_relative "app/services/real_rescan"
require_relative "app/services/execution/local_delivery_builder"
require_relative "app/services/ai/delivery_generator"
require_relative "app/services/commercial/proposal_builder"
require_relative "app/services/commercial/commercial_proposal_generator"
require_relative "app/services/automation/automation_event_logger"
require_relative "app/services/automation/automation_engine"
require_relative "app/services/notifications/system_notifier"
require_relative "app/services/concierge/concierge_engine"
require_relative "app/services/concierge/concierge_autopilot"
require_relative "app/services/concierge/concierge_decision_engine"
require_relative "app/routes/concierge_decision_executor_routes"
require_relative "app/services/concierge/concierge_decision_executor"
require_relative "app/services/payments/pix_payment_provider"
require_relative "app/services/responses/response_inbox_provider"
require_relative "app/services/responses/response_action_engine"
require_relative "app/services/validation/validation_engine"
require_relative "app/services/validation/sandbox_runner"
require_relative "app/services/jobs/job_runner"
require_relative "app/services/finance/financial_metrics_engine"
require_relative "app/services/ops/ops_monitoring_engine"
require_relative "app/services/ops/daily_operator_engine"
require_relative "app/services/ops/work_session_engine"
require_relative "app/services/ops/ops_heartbeat"
require_relative "app/services/jobs/job_queue"
require_relative "app/services/observability/observability_engine"
require_relative "app/services/channels/channel_dispatch_engine"
require_relative "app/services/outreach/outreach_policy"
require_relative "app/services/outreach/outreach_builder"
require_relative "app/services/outreach/manual_provider"
require_relative "app/services/outreach/outreach_engine"

require_relative "config/app_settings"
require_relative "config/env_guard"


before do
  begin
    @popup_notifications = SystemNotifier.new(DB).unread(3) if defined?(SystemNotifier) && defined?(DB)
  rescue
    @popup_notifications = []
  end
end

# Modular routes
enable :sessions
set :session_secret, AuthGuard.session_secret
set :protection, except: :session_hijacking

helpers AuthGuard

before do
  require_admin! unless public_request?(request.path_info)
end

require_relative "app/routes/delivery_routes"
require_relative "app/routes/commercial_routes"
require_relative "app/routes/dashboard_routes"
require_relative "app/routes/pipeline_routes"
require_relative "app/routes/static_routes"
require_relative "app/routes/finance_routes"
require_relative "app/routes/contact_routes"
require_relative "app/routes/automation_routes"
require_relative "app/routes/outreach_routes"
require_relative "app/routes/system_routes"
require_relative "app/routes/self_repair_routes"
require_relative "app/routes/settings_routes"
require_relative "app/routes/health_routes"
require_relative "app/routes/concierge_routes"
require_relative "app/routes/notification_routes"
require_relative "app/routes/channel_observability_routes"
require_relative "app/routes/payment_provider_routes"
require_relative "app/routes/response_inbox_routes"
require_relative "app/routes/response_action_routes"
require_relative "app/routes/revenue_autopilot_routes"
require_relative "app/routes/validation_routes"
require_relative "app/routes/validation_sandbox_routes"
require_relative "app/routes/job_routes"
require_relative "app/routes/financial_metrics_routes"
require_relative "app/routes/ops_monitoring_routes"
require_relative "app/routes/daily_operator_routes"
require_relative "app/routes/work_session_routes"
require_relative "app/routes/concierge_decision_routes"
require_relative "app/routes/deploy_routes"
require_relative "app/routes/auth_routes"





set :bind, "0.0.0.0"
set :port, ENV.fetch("PORT", 4567).to_i
set :public_folder, File.expand_path("app/public", __dir__)
set :views, File.expand_path("app/views", __dir__)

DATA_DIR = File.expand_path("data", __dir__)
DB_PATH = File.join(DATA_DIR, "sistema_autonomo.sqlite3")

FileUtils.mkdir_p(DATA_DIR)

unless File.exist?(DB_PATH)
  load File.expand_path("db/setup.rb", __dir__)
end

DB = SQLite3::Database.new(DB_PATH)
DB.results_as_hash = true

def db_all(sql, params = [])
  DB.execute(sql, params).map do |row|
    row.reject { |k, _| k.is_a?(Integer) }
  end
end

def db_one(sql, params = [])
  row = DB.get_first_row(sql, params)
  row&.reject { |k, _| k.is_a?(Integer) }
end

def create_deal_event(deal_id, event_type, title, description = nil, metadata = nil)
  DB.execute(
    <<~SQL,
      INSERT INTO deal_events
      (
        deal_id,
        event_type,
        title,
        description,
        metadata,
        created_at
      )
      VALUES (?, ?, ?, ?, ?, ?)
    SQL
    [
      deal_id,
      event_type,
      title,
      description,
      metadata,
      Time.now.iso8601
    ]
  )
end


def tasks
  db_all(
    <<~SQL
      SELECT *
      FROM tasks
      WHERE quality_status != 'ignore'
      ORDER BY
        CASE quality_status
          WHEN 'monetizable' THEN 3
          WHEN 'review' THEN 2
          ELSE 1
        END DESC,
        demand_score DESC,
        suggested_price DESC,
        id DESC
      LIMIT 250
    SQL
  )
end

def completed_tasks
  db_all("SELECT * FROM tasks WHERE status = 'ok' ORDER BY paid_at DESC, id DESC")
end

def possible_revenue
  row = db_one("SELECT COALESCE(SUM(suggested_price), 0) AS total FROM tasks WHERE status = 'ok'")
  row["total"].to_f
end

def system_stats
  total_tasks = db_one("SELECT COUNT(*) AS c FROM tasks")["c"].to_i
  ok_tasks = db_one("SELECT COUNT(*) AS c FROM tasks WHERE status = 'ok'")["c"].to_i
  total_deals = db_one("SELECT COUNT(*) AS c FROM deals")["c"].to_i rescue 0
  closed_deals = db_one("SELECT COUNT(*) AS c FROM deals WHERE status = 'fechado'")["c"].to_i rescue 0

  paid_revenue = db_one("SELECT COALESCE(SUM(amount), 0) AS total FROM payments WHERE status = 'paid'")["total"].to_f rescue 0
  pending_revenue = db_one("SELECT COALESCE(SUM(amount), 0) AS total FROM payments WHERE status = 'pending'")["total"].to_f rescue 0

  ai_deliveries = db_one("SELECT COUNT(*) AS c FROM deliveries WHERE generator_type = 'ai'")["c"].to_i rescue 0
  fallback_deliveries = db_one("SELECT COUNT(*) AS c FROM deliveries WHERE generator_type = 'fallback'")["c"].to_i rescue 0
  total_deliveries = db_one("SELECT COUNT(*) AS c FROM deliveries")["c"].to_i rescue 0

  last_log_path = File.expand_path("storage/logs/rescan_worker.log", __dir__)
  last_rescan = "Sem log ainda"

  if File.exist?(last_log_path)
    lines = File.readlines(last_log_path).reverse
    found = lines.find { |line| line.include?("RESCAN_OK") || line.include?("RESCAN_ERROR") }
    last_rescan = found ? found.strip : "Worker iniciado, sem rescan OK ainda"
  end

  conversion_rate =
    if total_deals > 0
      ((closed_deals.to_f / total_deals.to_f) * 100).round(1)
    else
      0
    end

  {
    total_tasks: total_tasks,
    tasks_per_day: db_one("SELECT COUNT(*) AS c FROM tasks WHERE date(created_at) = date('now')")["c"].to_i,
    manual_time: "45m",
    automation_rate: "REAL",
    active_robots: 2,
    completed: ok_tasks,
    possible_revenue: possible_revenue,

    paid_revenue: paid_revenue,
    pending_revenue: pending_revenue,
    total_deals: total_deals,
    closed_deals: closed_deals,
    conversion_rate: conversion_rate,
    ai_deliveries: ai_deliveries,
    fallback_deliveries: fallback_deliveries,
    total_deliveries: total_deliveries,
    last_rescan: last_rescan
  }
end




