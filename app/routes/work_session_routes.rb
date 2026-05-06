get "/work-session" do
  @page = "work_session"
  @dashboard = WorkSessionEngine.new(DB).dashboard

  erb :work_session
end

get "/work-session.json" do
  content_type :json
  JSON.generate(WorkSessionEngine.new(DB).dashboard)
end

post "/work-session/start" do
  WorkSessionEngine.new(DB).start_session
  redirect "/work-session"
end

post "/work-session/end" do
  WorkSessionEngine.new(DB).end_session(notes: params[:notes])
  redirect "/work-session"
end

post "/work-session/run-cycle" do
  WorkSessionEngine.new(DB).run_daily_cycle
  redirect "/work-session"
end

post "/work-session/log" do
  WorkSessionEngine.new(DB).log_event(
    event_type: params[:event_type] || "manual_note",
    title: params[:title] || "Nota manual",
    body: params[:body],
    link: params[:link]
  )

  redirect "/work-session"
end
