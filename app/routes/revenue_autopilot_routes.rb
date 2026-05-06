get "/revenue-autopilot" do
  @page = "revenue_autopilot"

  @log_path = File.expand_path("storage/logs/revenue_autopilot.log", settings.root)

  @logs =
    if File.exist?(@log_path)
      File.readlines(@log_path).last(150).reverse
    else
      ["Nenhum ciclo do Revenue Autopilot executado ainda."]
    end

  @notifications = db_all(
    <<~SQL
      SELECT *
      FROM system_notifications
      ORDER BY id DESC
      LIMIT 20
    SQL
  )

  @signals = db_all(
    <<~SQL
      SELECT *
      FROM observability_signals
      WHERE status = 'open'
      ORDER BY id DESC
      LIMIT 20
    SQL
  )

  erb :revenue_autopilot
end

post "/revenue-autopilot/run" do
  system("ruby workers/revenue_autopilot_worker.rb --once >> storage/logs/revenue_autopilot_web.log 2>&1")
  redirect "/revenue-autopilot"
end
