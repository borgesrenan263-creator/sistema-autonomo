get "/validation" do
  @page = "validation"

  @runs = db_all(
    <<~SQL
      SELECT validation_runs.*, deliveries.version AS delivery_version
      FROM validation_runs
      LEFT JOIN deliveries ON deliveries.id = validation_runs.delivery_id
      ORDER BY validation_runs.id DESC
      LIMIT 150
    SQL
  )

  @deliveries = db_all(
    <<~SQL
      SELECT id, task_id, version, validation_status, validation_score, validated_at, created_at
      FROM deliveries
      ORDER BY id DESC
      LIMIT 100
    SQL
  )

  erb :validation
end

post "/validation/run" do
  ValidationEngine.new(DB).validate_latest
  redirect "/validation"
end

post "/deliveries/:id/validate" do
  ValidationEngine.new(DB).validate_delivery(params[:id])
  redirect "/deliveries/#{params[:id]}"
end
