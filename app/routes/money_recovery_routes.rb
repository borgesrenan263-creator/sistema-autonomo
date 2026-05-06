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
