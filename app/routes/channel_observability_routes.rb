get "/channels" do
  @page = "channels"

  @dispatches = db_all(
    <<~SQL
      SELECT *
      FROM channel_dispatches
      ORDER BY id DESC
      LIMIT 200
    SQL
  )

  erb :channels
end

post "/channels/sync" do
  ChannelDispatchEngine.new(DB).sync_outbox
  redirect "/channels"
end

post "/channels/run" do
  ChannelDispatchEngine.new(DB).run_once
  redirect "/channels"
end

get "/observability" do
  @page = "observability"

  @signals = db_all(
    <<~SQL
      SELECT *
      FROM observability_signals
      ORDER BY
        CASE status
          WHEN 'open' THEN 1
          ELSE 2
        END,
        id DESC
      LIMIT 300
    SQL
  )

  erb :observability
end

post "/observability/scan" do
  ObservabilityEngine.new(DB).scan
  redirect "/observability"
end
