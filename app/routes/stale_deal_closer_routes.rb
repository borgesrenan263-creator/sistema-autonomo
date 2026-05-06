require_relative "../services/revenue/stale_deal_closer"

get "/money/stale-deals" do
  @page = "stale_deals"
  @days = (params[:days] || "7").to_i
  @days = 7 if @days <= 0
  @stale_deals = StaleDealCloser.new(DB).preview(days: @days)

  erb :stale_deals
end

get "/money/stale-deals.json" do
  content_type :json

  days = (params[:days] || "7").to_i
  days = 7 if days <= 0

  JSON.pretty_generate({
    generated_at: Time.now.utc.iso8601,
    days: days,
    candidates: StaleDealCloser.new(DB).preview(days: days)
  })
end

post "/money/stale-deals/close" do
  days = (params[:days] || "7").to_i
  days = 7 if days <= 0

  StaleDealCloser.new(DB).run_once(days: days)

  redirect "/money/stale-deals?days=#{days}"
end
