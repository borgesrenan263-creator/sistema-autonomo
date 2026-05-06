get "/uptime" do
  snapshot = OpsMonitoringEngine.new(DB).snapshot

  content_type :json

  status_code =
    if snapshot[:database][:ok] && snapshot[:jobs][:stuck].to_i == 0
      200
    else
      503
    end

  status status_code

  JSON.generate(
    ok: status_code == 200,
    database: snapshot[:database],
    jobs: {
      failed: snapshot[:jobs][:failed],
      stuck: snapshot[:jobs][:stuck],
      queued: snapshot[:jobs][:queued],
      running: snapshot[:jobs][:running]
    },
    alerts_count: snapshot[:alerts].count,
    time: Time.now.iso8601
  )
end

get "/ops/monitoring" do
  @page = "ops_monitoring"
  @snapshot = OpsMonitoringEngine.new(DB).snapshot

  erb :ops_monitoring
end

get "/ops/monitoring.json" do
  content_type :json
  JSON.generate(OpsMonitoringEngine.new(DB).snapshot)
end

post "/ops/heartbeat/:component" do
  OpsHeartbeat.new(DB).beat(
    component: params[:component],
    status: params[:status] || "ok",
    detail: params[:detail],
    metadata: {}
  )

  redirect "/ops/monitoring"
end
