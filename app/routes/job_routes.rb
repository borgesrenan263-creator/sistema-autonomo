get "/jobs" do
  @page = "jobs"

  @jobs = db_all(
    <<~SQL
      SELECT *
      FROM jobs
      ORDER BY
        CASE status
          WHEN 'running' THEN 1
          WHEN 'queued' THEN 2
          WHEN 'failed' THEN 3
          ELSE 4
        END,
        id DESC
      LIMIT 200
    SQL
  )

  @events = db_all(
    "SELECT * FROM job_events ORDER BY id DESC LIMIT 100"
  )

  erb :jobs
end

post "/jobs/seed-revenue-cycle" do
  JobRunner.new(DB).seed_revenue_cycle
  redirect "/jobs"
end

post "/jobs/run-next" do
  JobRunner.new(DB).run_next
  redirect "/jobs"
end

post "/jobs/run-batch" do
  JobRunner.new(DB).run_batch(10)
  redirect "/jobs"
end

post "/jobs/enqueue/:type" do
  JobQueue.new(DB).enqueue(
    job_type: params[:type],
    payload: {},
    priority: (params[:priority] || 50).to_i
  )

  redirect "/jobs"
end
