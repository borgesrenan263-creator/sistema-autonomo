get "/concierge" do
  @page = "concierge"

  ConciergeEngine.new(DB).sync_all

  @requests = db_all(
    <<~SQL
      SELECT
        concierge_requests.*,
        tasks.title AS task_title,
        deals.status AS deal_status,
        deals.value AS deal_value,
        automation_flows.current_state,
        automation_flows.next_action,
        automation_flows.status AS flow_status,
        automation_flows.last_error
      FROM concierge_requests
      LEFT JOIN tasks ON tasks.id = concierge_requests.task_id
      LEFT JOIN deals ON deals.id = concierge_requests.deal_id
      LEFT JOIN automation_flows ON automation_flows.id = concierge_requests.flow_id
      ORDER BY
        CASE concierge_requests.status
          WHEN 'pending' THEN 1
          ELSE 2
        END,
        concierge_requests.id DESC
      LIMIT 200
    SQL
  )

  @events = db_all(
    "SELECT * FROM concierge_events ORDER BY id DESC LIMIT 80"
  )

  erb :concierge
end

post "/concierge/sync" do
  ConciergeEngine.new(DB).sync_all
  redirect "/concierge"
end

post "/concierge/requests/:id/approve" do
  ConciergeEngine.new(DB).approve_request(
    params[:id],
    response_status: params[:response_status]
  )

  redirect "/concierge"
end

post "/concierge/requests/:id/reject" do
  ConciergeEngine.new(DB).reject_request(params[:id])
  redirect "/concierge"
end
