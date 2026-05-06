# frozen_string_literal: true

require_relative "../services/ops/autopilot_daily_loop_engine"

get "/autopilot/daily-loop" do
  @snapshot = AutopilotDailyLoopEngine.new(DB).snapshot
  erb :autopilot_daily_loop
end

get "/autopilot/daily-loop.json" do
  content_type :json
  JSON.pretty_generate(AutopilotDailyLoopEngine.new(DB).snapshot)
end

post "/autopilot/daily-loop/run" do
  AutopilotDailyLoopEngine.new(DB).run!(trigger_source: "manual_route")
  redirect "/autopilot/daily-loop"
end


post "/autopilot/daily-loop/enqueue" do
  now = Time.now.utc.iso8601

  DB.execute(
    "INSERT INTO jobs (job_type, status, priority, attempts, max_attempts, payload, run_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    ["autopilot_daily_loop", "queued", 90, 0, 3, "{}", now, now, now]
  )

  redirect "/autopilot/daily-loop"
end
