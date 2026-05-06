get "/responses/action-center" do
  @page = "response_action_center"
  @filter = params[:filter] || "open"
  @dashboard = ResponseActionEngine.new(DB).dashboard(filter: @filter)

  erb :response_action_center
end

get "/responses/action-center.json" do
  content_type :json
  filter = params[:filter] || "open"
  JSON.generate(ResponseActionEngine.new(DB).dashboard(filter: filter))
end

post "/responses/:id/resolve" do
  ResponseActionEngine.new(DB).mark_resolved(params[:id], note: params[:note])
  redirect "/responses/action-center"
end

post "/responses/:id/ignore" do
  ResponseActionEngine.new(DB).ignore(params[:id], note: params[:note])
  redirect "/responses/action-center"
end

post "/responses/:id/mark-interested" do
  ResponseActionEngine.new(DB).mark_interested(params[:id])
  redirect "/responses/action-center"
end

post "/responses/:id/create-charge" do
  ResponseActionEngine.new(DB).create_manual_charge(params[:id])
  redirect "/responses/action-center"
end

get "/responses/:id/suggested-message" do
  content_type :text
  ResponseActionEngine.new(DB).suggested_message(params[:id])
end
