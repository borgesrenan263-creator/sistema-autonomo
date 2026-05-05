get "/automations" do
  @page = "automations"

  @flows = db_all(
    <<~SQL
      SELECT
        automation_flows.*,
        tasks.title AS task_title,
        tasks.source,
        deals.status AS deal_status,
        deals.value AS deal_value
      FROM automation_flows
      INNER JOIN tasks ON tasks.id = automation_flows.task_id
      LEFT JOIN deals ON deals.id = automation_flows.deal_id
      ORDER BY automation_flows.id DESC
      LIMIT 250
    SQL
  )

  erb :automations
end

post "/tasks/:id/automation/start" do
  task = db_one("SELECT * FROM tasks WHERE id = ?", [params[:id]])
  halt 404, "Task não encontrada" unless task

  engine = AutomationEngine.new(DB)
  flow = engine.start_for_task(params[:id])

  redirect "/automations/#{flow["id"]}"
end

post "/automations/:id/run-next" do
  engine = AutomationEngine.new(DB)
  engine.run_next(params[:id])

  redirect "/automations/#{params[:id]}"
end

post "/automations/:id/resume" do
  flow = db_one("SELECT * FROM automation_flows WHERE id = ?", [params[:id]])
  halt 404, "Fluxo não encontrado" unless flow

  DB.execute(
    "UPDATE automation_flows SET status = 'running', last_error = NULL, locked = 0, updated_at = ? WHERE id = ?",
    [Time.now.iso8601, params[:id]]
  )

  redirect "/automations/#{params[:id]}"
end

post "/automations/:id/cancel" do
  flow = db_one("SELECT * FROM automation_flows WHERE id = ?", [params[:id]])
  halt 404, "Fluxo não encontrado" unless flow

  DB.execute(
    "UPDATE automation_flows SET status = 'cancelled', current_state = 'cancelled', next_action = NULL, locked = 0, updated_at = ?, completed_at = ? WHERE id = ?",
    [Time.now.iso8601, Time.now.iso8601, params[:id]]
  )

  redirect "/automations/#{params[:id]}"
end

get "/automations/:id" do
  @page = "automations"

  @flow = db_one(
    <<~SQL,
      SELECT
        automation_flows.*,
        tasks.title AS task_title,
        tasks.source,
        tasks.url,
        tasks.quality_status,
        tasks.quality_reason,
        tasks.demand_score,
        tasks.suggested_price,
        deals.status AS deal_status,
        deals.value AS deal_value,
        deals.contact_id
      FROM automation_flows
      INNER JOIN tasks ON tasks.id = automation_flows.task_id
      LEFT JOIN deals ON deals.id = automation_flows.deal_id
      WHERE automation_flows.id = ?
    SQL
    [params[:id]]
  )

  halt 404, "Fluxo não encontrado" unless @flow

  @steps = db_all(
    "SELECT * FROM automation_steps WHERE flow_id = ? ORDER BY id DESC LIMIT 100",
    [params[:id]]
  )

  @events = db_all(
    "SELECT * FROM automation_events WHERE flow_id = ? ORDER BY id DESC LIMIT 100",
    [params[:id]]
  )

  erb :automation_show
end

