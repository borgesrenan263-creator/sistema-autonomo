get "/healthz" do
  content_type :json
  JSON.generate(
    ok: true,
    app: "sistema-autonomo",
    status: "alive",
    time: Time.now.iso8601
  )
end

get "/readyz" do
  begin
    DB.test_connection

    content_type :json
    JSON.generate(
      ok: true,
      app: "sistema-autonomo",
      status: "ready",
      database: DatabaseConfig.adapter,
      time: Time.now.iso8601
    )
  rescue => e
    status 503
    content_type :json
    JSON.generate(
      ok: false,
      status: "not_ready",
      error: "#{e.class}: #{e.message}",
      time: Time.now.iso8601
    )
  end
end
