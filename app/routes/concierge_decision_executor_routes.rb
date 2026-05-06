get "/concierge/executor" do
  @page = "concierge_executor"
  @dashboard = ConciergeDecisionExecutor.new(DB).dashboard

  erb :concierge_executor
end

get "/concierge/executor.json" do
  content_type :json
  JSON.generate(ConciergeDecisionExecutor.new(DB).dashboard)
end

post "/concierge/executor/run" do
  ConciergeDecisionExecutor.new(DB).run_batch(20)
  redirect "/concierge/executor"
end

post "/concierge/executor/:id" do
  ConciergeDecisionExecutor.new(DB).execute(params[:id])
  redirect "/concierge/executor"
end
