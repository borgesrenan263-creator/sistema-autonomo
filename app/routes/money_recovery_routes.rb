require_relative "../services/revenue/money_recovery_engine"

get "/money/recovery" do
  @page = "money_recovery"
  @money_recovery = MoneyRecoveryEngine.new(DB).snapshot
  erb :money_recovery
end

get "/money/recovery.json" do
  content_type :json
  JSON.pretty_generate(MoneyRecoveryEngine.new(DB).snapshot)
end


post "/money/recovery/run-followups" do
  require_relative "../services/revenue/followup_autopilot_engine"

  engine = FollowupAutopilotEngine.new(DB)
  engine.scan
  engine.run_due

  redirect "/money/recovery"
end

post "/money/recovery/run-dispatch" do
  require_relative "../services/channels/dispatch_autopilot_engine"

  DispatchAutopilotEngine.new(DB).run_once

  redirect "/money/recovery"
end

post "/money/recovery/run-daily-loop" do
  require_relative "../services/ops/autopilot_daily_loop_engine"

  AutopilotDailyLoopEngine.new(DB).run!(trigger_source: "money_recovery")

  redirect "/money/recovery"
end


post "/money/recovery/recover-daily-limit" do
  require_relative "../services/channels/dispatch_autopilot_engine"

  DispatchAutopilotEngine.new(DB).recover_waiting_limit(limit: 10)

  redirect "/money/recovery"
end

