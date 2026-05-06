require_relative "../services/ops/operational_queue_engine"

get "/ops/queue" do
  @page = "ops_queue"
  @queue_snapshot = OperationalQueueEngine.new(DB).snapshot
  erb :ops_queue
end

get "/ops/queue.json" do
  content_type :json
  JSON.pretty_generate(OperationalQueueEngine.new(DB).snapshot)
end

post "/ops/queue/:id/cancel" do
  result = OperationalQueueEngine.new(DB).cancel_job(
    params[:id],
    reason: params[:reason].to_s.empty? ? "cancelled_by_operator" : params[:reason].to_s
  )

  redirect "/ops/queue"
end
