get "/validation/sandbox" do
  @page = "validation_sandbox"

  @runs = db_all(
    <<~SQL
      SELECT *
      FROM validation_sandbox_runs
      ORDER BY id DESC
      LIMIT 150
    SQL
  )

  erb :validation_sandbox
end

post "/validation/sandbox/run" do
  SandboxRunner.new(DB).run_latest(5)
  redirect "/validation/sandbox"
end

post "/deliveries/:id/sandbox" do
  SandboxRunner.new(DB).run_for_delivery(params[:id])
  redirect "/validation/sandbox"
end
