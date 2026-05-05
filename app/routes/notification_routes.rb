get "/notifications" do
  @page = "notifications"

  @notifications = db_all(
    <<~SQL
      SELECT *
      FROM system_notifications
      ORDER BY id DESC
      LIMIT 200
    SQL
  )

  erb :notifications
end

post "/notifications/:id/read" do
  DB.execute(
    "UPDATE system_notifications SET status = 'read', read_at = ? WHERE id = ?",
    [Time.now.iso8601, params[:id]]
  )

  redirect back
end

post "/concierge/autopilot/run" do
  ConciergeAutopilot.new(DB).run_once
  redirect "/concierge"
end
