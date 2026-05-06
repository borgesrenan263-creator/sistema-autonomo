get "/dispatch/autopilot" do
  @page = "dispatch_autopilot"
  @dashboard = DispatchAutopilotEngine.new(DB).dashboard

  erb :dispatch_autopilot
end

get "/dispatch/autopilot.json" do
  content_type :json
  JSON.generate(DispatchAutopilotEngine.new(DB).dashboard)
end

post "/dispatch/autopilot/run" do
  DispatchAutopilotEngine.new(DB).run(20)
  redirect "/dispatch/autopilot"
end

post "/dispatch/autopilot/:id/process" do
  DispatchAutopilotEngine.new(DB).process_one(params[:id])
  redirect "/dispatch/autopilot"
end
