get "/concierge/decisions" do
  @page = "concierge_decisions"
  @dashboard = ConciergeDecisionEngine.new(DB).dashboard

  erb :concierge_decisions
end

get "/concierge/decisions.json" do
  content_type :json
  JSON.generate(ConciergeDecisionEngine.new(DB).dashboard)
end

post "/concierge/decisions/run" do
  ConciergeDecisionEngine.new(DB).run_batch(20)
  redirect "/concierge/decisions"
end

post "/concierge/decisions/response/:id" do
  ConciergeDecisionEngine.new(DB).evaluate_response(params[:id])
  redirect "/concierge/decisions"
end

post "/concierge/decisions/delivery/:id" do
  ConciergeDecisionEngine.new(DB).evaluate_delivery(params[:id])
  redirect "/concierge/decisions"
end

post "/concierge/decisions/task/:id" do
  ConciergeDecisionEngine.new(DB).evaluate_opportunity(params[:id])
  redirect "/concierge/decisions"
end
