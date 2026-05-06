get "/followups/autopilot" do
  @page = "followup_autopilot"
  @dashboard = FollowupAutopilotEngine.new(DB).dashboard

  erb :followup_autopilot
end

get "/followups/autopilot.json" do
  content_type :json
  JSON.generate(FollowupAutopilotEngine.new(DB).dashboard)
end

post "/followups/autopilot/scan" do
  FollowupAutopilotEngine.new(DB).scan
  redirect "/followups/autopilot"
end

post "/followups/autopilot/run-due" do
  FollowupAutopilotEngine.new(DB).run_due(20)
  redirect "/followups/autopilot"
end

post "/followups/autopilot/:id/process" do
  FollowupAutopilotEngine.new(DB).process_followup(params[:id])
  redirect "/followups/autopilot"
end

post "/followups/autopilot/:id/done" do
  FollowupAutopilotEngine.new(DB).mark_done(params[:id])
  redirect "/followups/autopilot"
end

post "/followups/autopilot/:id/lost" do
  FollowupAutopilotEngine.new(DB).mark_lost(params[:id])
  redirect "/followups/autopilot"
end
