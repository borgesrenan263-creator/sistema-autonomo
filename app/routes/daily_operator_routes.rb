get "/command-center" do
  @page = "command_center"
  @snapshot = DailyOperatorEngine.new(DB).snapshot

  erb :daily_operator
end

get "/command-center.json" do
  content_type :json
  JSON.generate(DailyOperatorEngine.new(DB).snapshot)
end

post "/command-center/run-cycle" do
  if defined?(JobRunner)
    JobRunner.new(DB).seed_revenue_cycle
  end

  redirect "/command-center"
end
