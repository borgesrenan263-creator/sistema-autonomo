get "/responses/inbox" do
  @page = "response_inbox"

  @events = db_all(
    <<~SQL
      SELECT *
      FROM response_inbox_events
      ORDER BY id DESC
      LIMIT 150
    SQL
  )

  @outreach = db_all(
    <<~SQL
      SELECT *
      FROM outreach_messages
      ORDER BY id DESC
      LIMIT 80
    SQL
  )

  erb :response_inbox
end

post "/webhooks/responses" do
  request.body.rewind
  raw_body = request.body.read

  result = ResponseInboxProvider.new(DB).handle_webhook(
    raw_body: raw_body,
    headers: request.env
  )

  status result[:status]
  content_type :json
  JSON.generate(result)
end
