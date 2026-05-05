get "/payments/provider" do
  @page = "payment_provider"

  @events = db_all(
    <<~SQL
      SELECT *
      FROM pix_webhook_events
      ORDER BY id DESC
      LIMIT 100
    SQL
  )

  @payments = db_all(
    <<~SQL
      SELECT *
      FROM payments
      ORDER BY id DESC
      LIMIT 50
    SQL
  )

  erb :payment_provider
end

post "/webhooks/pix" do
  request.body.rewind
  raw_body = request.body.read

  result = PixPaymentProvider.new(DB).handle_webhook(
    raw_body: raw_body,
    headers: request.env
  )

  status result[:status]
  content_type :json
  JSON.generate(result)
end
