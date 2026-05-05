post "/tasks/:id/execute" do
  task = db_one("SELECT * FROM tasks WHERE id = ?", [params[:id]])

  halt 404, "Tarefa não encontrada" unless task

  delivery = DeliveryGenerator.generate(task)
  now = Time.now.iso8601

  last_version_row = db_one("SELECT COALESCE(MAX(version), 0) AS version FROM deliveries WHERE task_id = ?", [params[:id]])
  next_version = last_version_row["version"].to_i + 1

  DB.execute(
    <<~SQL,
      INSERT INTO deliveries
      (
        task_id,
        version,
        category,
        content,
        status,
        created_at,
        updated_at,
        generator_type,
        provider,
        model,
        error_message
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL
    [
      params[:id],
      next_version,
      delivery[:category],
      delivery[:content],
      "ready",
      now,
      now,
      delivery[:generator_type],
      delivery[:provider],
      delivery[:model],
      delivery[:error_message]
    ]
  )

  DB.execute(
    <<~SQL,
      UPDATE tasks
      SET status = 'faturamento',
          stage = 'faturamento',
          result = ?,
          executed_at = ?,
          updated_at = ?
      WHERE id = ?
    SQL
    [delivery[:content], now, now, params[:id]]
  )

  redirect "/pipeline"
end

post "/tasks/:id/ok" do
  DB.execute(
    <<~SQL,
      UPDATE tasks
      SET status = 'ok',
          stage = 'historico',
          paid_at = ?,
          updated_at = ?
      WHERE id = ?
    SQL
    [Time.now.iso8601, Time.now.iso8601, params[:id]]
  )

  redirect "/historico"
end

get "/export/csv" do
  content_type "text/csv"
  attachment "historico_receitas.csv"

  CSV.generate do |csv|
    csv << ["id", "external_id", "fonte", "titulo", "url", "demanda", "valor", "status", "paid_at"]

    completed_tasks.each do |task|
      csv << [
        task["id"],
        task["external_id"],
        task["source"],
        task["title"],
        task["url"],
        task["demand_score"],
        task["suggested_price"],
        task["status"],
        task["paid_at"]
      ]
    end
  end
end

get "/deliveries/:id" do
  @page = "pipeline"
  @delivery = db_one(
    <<~SQL,
      SELECT deliveries.*, tasks.title, tasks.source, tasks.url, tasks.suggested_price
      FROM deliveries
      INNER JOIN tasks ON tasks.id = deliveries.task_id
      WHERE deliveries.id = ?
    SQL
    [params[:id]]
  )

  halt 404, "Entrega não encontrada" unless @delivery

  erb :delivery_show
end

get "/entregas" do
  @page = "entregas"

  @deliveries = db_all(
    <<~SQL
      SELECT
        deliveries.*,
        tasks.title,
        tasks.source,
        tasks.url,
        tasks.suggested_price,
        tasks.quality_status
      FROM deliveries
      INNER JOIN tasks ON tasks.id = deliveries.task_id
      ORDER BY deliveries.id DESC
      LIMIT 250
    SQL
  )

  @deliveries_summary = {
    total_deliveries: @deliveries.count,
    ready_deliveries: @deliveries.count { |d| d["status"] == "ready" },
    unique_tasks: @deliveries.map { |d| d["task_id"] }.uniq.count,
    unique_potential: @deliveries
      .group_by { |d| d["task_id"] }
      .values
      .sum { |items| items.first["suggested_price"].to_i }
  }

  erb :deliveries
end


get "/deliveries/:id/export.txt" do
  delivery = db_one(
    <<~SQL,
      SELECT deliveries.*, tasks.title, tasks.source
      FROM deliveries
      INNER JOIN tasks ON tasks.id = deliveries.task_id
      WHERE deliveries.id = ?
    SQL
    [params[:id]]
  )

  halt 404, "Entrega não encontrada" unless delivery

  safe_title = delivery["title"].to_s
    .downcase
    .gsub(/[^a-z0-9]+/, "-")
    .gsub(/^-|-$/, "")

  safe_title = "entrega" if safe_title.empty?

  filename = "entrega-#{delivery["id"]}-task-#{delivery["task_id"]}-#{safe_title[0, 50]}.txt"

  content_type "text/plain; charset=utf-8"
  attachment filename

  <<~TXT
    SISTEMA AUTÔNOMO — EXPORTAÇÃO TXT

    Entrega ID: #{delivery["id"]}
    Task ID: #{delivery["task_id"]}
    Versão: #{delivery["version"]}
    Fonte: #{delivery["source"]}
    Categoria: #{delivery["category"]}
    Status: #{delivery["status"]}
    Gerador: #{delivery["generator_type"] || "local"}
    Provider: #{delivery["provider"] || "local"}
    Modelo: #{delivery["model"] || "local_delivery_builder"}
    Criada em: #{delivery["created_at"]}

    Título:
    #{delivery["title"]}

    ------------------------------------------------------------

    #{delivery["content"]}
  TXT
end

