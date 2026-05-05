require "sinatra"
require "json"
require "time"
require "fileutils"
require "csv"
require "sqlite3"

require_relative "app/services/real_rescan"
require_relative "app/services/execution/local_delivery_builder"
require_relative "app/services/ai/delivery_generator"
require_relative "app/services/commercial/proposal_builder"
require_relative "app/services/commercial/commercial_proposal_generator"

set :bind, "0.0.0.0"
set :port, 4567
set :public_folder, File.expand_path("app/public", __dir__)
set :views, File.expand_path("app/views", __dir__)

DATA_DIR = File.expand_path("data", __dir__)
DB_PATH = File.join(DATA_DIR, "sistema_autonomo.sqlite3")

FileUtils.mkdir_p(DATA_DIR)

unless File.exist?(DB_PATH)
  load File.expand_path("db/setup.rb", __dir__)
end

DB = SQLite3::Database.new(DB_PATH)
DB.results_as_hash = true

def db_all(sql, params = [])
  DB.execute(sql, params).map do |row|
    row.reject { |k, _| k.is_a?(Integer) }
  end
end

def db_one(sql, params = [])
  row = DB.get_first_row(sql, params)
  row&.reject { |k, _| k.is_a?(Integer) }
end

def create_deal_event(deal_id, event_type, title, description = nil, metadata = nil)
  DB.execute(
    <<~SQL,
      INSERT INTO deal_events
      (
        deal_id,
        event_type,
        title,
        description,
        metadata,
        created_at
      )
      VALUES (?, ?, ?, ?, ?, ?)
    SQL
    [
      deal_id,
      event_type,
      title,
      description,
      metadata,
      Time.now.iso8601
    ]
  )
end


def tasks
  db_all(
    <<~SQL
      SELECT *
      FROM tasks
      WHERE quality_status != 'ignore'
      ORDER BY
        CASE quality_status
          WHEN 'monetizable' THEN 3
          WHEN 'review' THEN 2
          ELSE 1
        END DESC,
        demand_score DESC,
        suggested_price DESC,
        id DESC
      LIMIT 250
    SQL
  )
end

def completed_tasks
  db_all("SELECT * FROM tasks WHERE status = 'ok' ORDER BY paid_at DESC, id DESC")
end

def possible_revenue
  row = db_one("SELECT COALESCE(SUM(suggested_price), 0) AS total FROM tasks WHERE status = 'ok'")
  row["total"].to_f
end

def system_stats
  total_tasks = db_one("SELECT COUNT(*) AS c FROM tasks")["c"].to_i
  ok_tasks = db_one("SELECT COUNT(*) AS c FROM tasks WHERE status = 'ok'")["c"].to_i
  total_deals = db_one("SELECT COUNT(*) AS c FROM deals")["c"].to_i rescue 0
  closed_deals = db_one("SELECT COUNT(*) AS c FROM deals WHERE status = 'fechado'")["c"].to_i rescue 0

  paid_revenue = db_one("SELECT COALESCE(SUM(amount), 0) AS total FROM payments WHERE status = 'paid'")["total"].to_f rescue 0
  pending_revenue = db_one("SELECT COALESCE(SUM(amount), 0) AS total FROM payments WHERE status = 'pending'")["total"].to_f rescue 0

  ai_deliveries = db_one("SELECT COUNT(*) AS c FROM deliveries WHERE generator_type = 'ai'")["c"].to_i rescue 0
  fallback_deliveries = db_one("SELECT COUNT(*) AS c FROM deliveries WHERE generator_type = 'fallback'")["c"].to_i rescue 0
  total_deliveries = db_one("SELECT COUNT(*) AS c FROM deliveries")["c"].to_i rescue 0

  last_log_path = File.expand_path("storage/logs/rescan_worker.log", __dir__)
  last_rescan = "Sem log ainda"

  if File.exist?(last_log_path)
    lines = File.readlines(last_log_path).reverse
    found = lines.find { |line| line.include?("RESCAN_OK") || line.include?("RESCAN_ERROR") }
    last_rescan = found ? found.strip : "Worker iniciado, sem rescan OK ainda"
  end

  conversion_rate =
    if total_deals > 0
      ((closed_deals.to_f / total_deals.to_f) * 100).round(1)
    else
      0
    end

  {
    total_tasks: total_tasks,
    tasks_per_day: db_one("SELECT COUNT(*) AS c FROM tasks WHERE date(created_at) = date('now')")["c"].to_i,
    manual_time: "45m",
    automation_rate: "REAL",
    active_robots: 2,
    completed: ok_tasks,
    possible_revenue: possible_revenue,

    paid_revenue: paid_revenue,
    pending_revenue: pending_revenue,
    total_deals: total_deals,
    closed_deals: closed_deals,
    conversion_rate: conversion_rate,
    ai_deliveries: ai_deliveries,
    fallback_deliveries: fallback_deliveries,
    total_deliveries: total_deliveries,
    last_rescan: last_rescan
  }
end

get "/" do
  @page = "dashboard"
  @tasks = tasks
  @stats = system_stats
  erb :dashboard
end

get "/pipeline" do
  @page = "pipeline"
  @tasks = tasks
  @stats = system_stats
  erb :pipeline
end

get "/historico" do
  @page = "historico"
  @tasks = tasks
  @completed_tasks = completed_tasks
  @stats = system_stats
  erb :historico
end

get "/manifesto" do
  @page = "manifesto"
  @stats = system_stats
  erb :manifesto
end

post "/force-rescan" do
  result = RealRescan.new(DB).call
  redirect "/pipeline?inserted=#{result[:inserted]}&skipped=#{result[:skipped]}&total=#{result[:total]}"
end

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

get "/sistema" do
  @page = "sistema"

  log_path = File.expand_path("storage/logs/rescan_worker.log", __dir__)

  @logs =
    if File.exist?(log_path)
      File.readlines(log_path).last(80).reverse
    else
      []
    end

  @system_counts = {
    total_tasks: db_one("SELECT COUNT(*) AS c FROM tasks")["c"],
    github_tasks: db_one("SELECT COUNT(*) AS c FROM tasks WHERE source = 'GitHub'")["c"],
    hn_tasks: db_one("SELECT COUNT(*) AS c FROM tasks WHERE source = 'Hacker News'")["c"],
    monetizable: db_one("SELECT COUNT(*) AS c FROM tasks WHERE quality_status = 'monetizable'")["c"],
    review: db_one("SELECT COUNT(*) AS c FROM tasks WHERE quality_status = 'review'")["c"],
    ignored: db_one("SELECT COUNT(*) AS c FROM tasks WHERE quality_status = 'ignore'")["c"],
    deliveries: db_one("SELECT COUNT(*) AS c FROM deliveries")["c"],
    ok_tasks: db_one("SELECT COUNT(*) AS c FROM tasks WHERE status = 'ok'")["c"]
  }

  @last_tasks = db_all(
    <<~SQL
      SELECT id, source, quality_status, demand_score, suggested_price, title, created_at
      FROM tasks
      ORDER BY id DESC
      LIMIT 12
    SQL
  )

  erb :sistema
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

post "/tasks/:id/proposal" do
  task = db_one("SELECT * FROM tasks WHERE id = ?", [params[:id]])
  halt 404, "Tarefa não encontrada" unless task

  existing_open_deal = db_one(
    <<~SQL,
      SELECT deals.*, proposals.id AS proposal_id
      FROM deals
      LEFT JOIN proposals ON proposals.id = deals.proposal_id
      WHERE deals.task_id = ?
        AND deals.status IN ('proposta_criada', 'abordado', 'interessado')
      ORDER BY deals.id DESC
      LIMIT 1
    SQL
    [params[:id]]
  )

  if existing_open_deal && existing_open_deal["proposal_id"]
    redirect "/proposals/#{existing_open_deal["proposal_id"]}?duplicate=1"
  end

  delivery = db_one(
    "SELECT * FROM deliveries WHERE task_id = ? ORDER BY version DESC LIMIT 1",
    [params[:id]]
  )

  proposal = CommercialProposalGenerator.generate(task, delivery)
  now = Time.now.iso8601

  DB.execute(
    <<~SQL,
      INSERT INTO proposals
      (
        task_id,
        delivery_id,
        title,
        pain_summary,
        solution_scope,
        out_of_scope,
        price,
        estimated_timeline,
        approach_message,
        status,
        created_at,
        updated_at,
        generator_type,
        provider,
        model,
        error_message
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL
    [
      task["id"],
      delivery && delivery["id"],
      proposal[:title],
      proposal[:pain_summary],
      proposal[:solution_scope],
      proposal[:out_of_scope],
      proposal[:price],
      proposal[:estimated_timeline],
      proposal[:approach_message],
      "draft",
      now,
      now,
      proposal[:generator_type],
      proposal[:provider],
      proposal[:model],
      proposal[:error_message]
    ]
  )

  proposal_id = DB.last_insert_row_id

  DB.execute(
    <<~SQL,
      INSERT INTO deals
      (
        task_id,
        proposal_id,
        status,
        value,
        next_action,
        notes,
        created_at,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    SQL
    [
      task["id"],
      proposal_id,
      "proposta_criada",
      proposal[:price],
      "Revisar proposta antes de qualquer abordagem externa.",
      "Deal criado automaticamente a partir da task #{task["id"]}.",
      now,
      now
    ]
  )

  deal_id = DB.last_insert_row_id

  create_deal_event(
    deal_id,
    "proposal_created",
    "Proposta criada",
    "Proposta ##{proposal_id} criada automaticamente para a task #{task["id"]}.",
    "provider=#{proposal[:provider]};model=#{proposal[:model]};generator_type=#{proposal[:generator_type]}"
  )

  redirect "/proposals/#{proposal_id}"
end

get "/proposals/:id" do
  @page = "comercial"

  @proposal = db_one(
    <<~SQL,
      SELECT proposals.*, tasks.title AS task_title, tasks.source, tasks.url
      FROM proposals
      INNER JOIN tasks ON tasks.id = proposals.task_id
      WHERE proposals.id = ?
    SQL
    [params[:id]]
  )

  halt 404, "Proposta não encontrada" unless @proposal

  @deal = db_one("SELECT * FROM deals WHERE proposal_id = ? ORDER BY id DESC LIMIT 1", [params[:id]])

  erb :proposal_show
end

get "/comercial" do
  @page = "comercial"

  @deals = db_all(
    <<~SQL
      SELECT
        deals.*,
        tasks.title AS task_title,
        tasks.source,
        tasks.url,
        proposals.title AS proposal_title,
        contacts.name AS contact_name,
        contacts.handle AS contact_handle,
        contacts.platform AS contact_platform
      FROM deals
      INNER JOIN tasks ON tasks.id = deals.task_id
      LEFT JOIN proposals ON proposals.id = deals.proposal_id
      LEFT JOIN contacts ON contacts.id = deals.contact_id
      ORDER BY deals.id DESC
      LIMIT 250
    SQL
  )

  @contacts = db_all(
    <<~SQL
      SELECT *
      FROM contacts
      ORDER BY id DESC
      LIMIT 250
    SQL
  )

  @commercial_counts = {
    total_deals: @deals.count,
    propostas: @deals.count { |d| d["status"] == "proposta_criada" },
    abordados: @deals.count { |d| d["status"] == "abordado" },
    interessados: @deals.count { |d| d["status"] == "interessado" },
    fechados: @deals.count { |d| d["status"] == "fechado" },
    perdidos: @deals.count { |d| d["status"] == "perdido" },
    value_open: @deals.select { |d| ["proposta_criada", "abordado", "interessado"].include?(d["status"]) }.sum { |d| d["value"].to_i },
    value_closed: @deals.select { |d| d["status"] == "fechado" }.sum { |d| d["value"].to_i }
  }

  erb :commercial
end

post "/deals/:id/status" do
  allowed = ["proposta_criada", "abordado", "interessado", "fechado", "perdido"]
  status = params[:status].to_s

  halt 400, "Status inválido" unless allowed.include?(status)

  deal_before = db_one("SELECT * FROM deals WHERE id = ?", [params[:id]])
  halt 404, "Deal não encontrado" unless deal_before

  old_status = deal_before["status"]
  now = Time.now.iso8601
  closed_at = status == "fechado" ? now : nil

  DB.execute(
    "UPDATE deals SET status = ?, updated_at = ?, closed_at = COALESCE(?, closed_at) WHERE id = ?",
    [status, now, closed_at, params[:id]]
  )

  create_deal_event(
    params[:id],
    "status_changed",
    "Status alterado",
    "Deal alterado de #{old_status} para #{status}.",
    "old_status=#{old_status};new_status=#{status}"
  )

  if status == "fechado"
    deal = db_one("SELECT * FROM deals WHERE id = ?", [params[:id]])

    existing_payment = db_one("SELECT * FROM payments WHERE deal_id = ? LIMIT 1", [params[:id]])

    unless existing_payment
      DB.execute(
        <<~SQL,
          INSERT INTO payments
          (
            deal_id,
            task_id,
            amount,
            method,
            pix_label,
            status,
            reference,
            created_at,
            updated_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [
          deal["id"],
          deal["task_id"],
          deal["value"],
          "pix_manual",
          "PIX configurado",
          "pending",
          "deal-#{deal["id"]}",
          now,
          now
        ]
      )

      payment_id = DB.last_insert_row_id

      create_deal_event(
        params[:id],
        "payment_created",
        "Cobrança criada",
        "Cobrança Pix/manual ##{payment_id} criada no valor de R$ #{deal["value"]}.",
        "payment_id=#{payment_id};amount=#{deal["value"]};method=pix_manual"
      )
    end
  end

  redirect "/comercial"
end

post "/payments/:id/paid" do
  now = Time.now.iso8601

  payment = db_one("SELECT * FROM payments WHERE id = ?", [params[:id]])
  halt 404, "Pagamento não encontrado" unless payment

  DB.execute(
    "UPDATE payments SET status = 'paid', paid_at = ?, updated_at = ? WHERE id = ?",
    [now, now, params[:id]]
  )

  DB.execute(
    "UPDATE tasks SET status = 'ok', stage = 'historico', paid_at = ?, updated_at = ? WHERE id = ?",
    [now, now, payment["task_id"]]
  )

  if payment["deal_id"]
    create_deal_event(
      payment["deal_id"],
      "payment_paid",
      "Pagamento confirmado",
      "Pagamento ##{payment["id"]} confirmado no valor de R$ #{payment["amount"]}.",
      "payment_id=#{payment["id"]};amount=#{payment["amount"]};paid_at=#{now}"
    )
  end

  redirect "/financeiro"
end

get "/financeiro" do
  @page = "financeiro"

  @payments = db_all(
    <<~SQL
      SELECT payments.*, tasks.title AS task_title
      FROM payments
      INNER JOIN tasks ON tasks.id = payments.task_id
      ORDER BY payments.id DESC
      LIMIT 250
    SQL
  )

  @financial_summary = {
    pending: @payments.select { |p| p["status"] == "pending" }.sum { |p| p["amount"].to_i },
    paid: @payments.select { |p| p["status"] == "paid" }.sum { |p| p["amount"].to_i },
    pending_count: @payments.count { |p| p["status"] == "pending" },
    paid_count: @payments.count { |p| p["status"] == "paid" }
  }

  erb :financeiro
end

post "/deals/:id/acceptance" do
  deal = db_one("SELECT * FROM deals WHERE id = ?", [params[:id]])
  halt 404, "Deal não encontrado" unless deal

  delivery = db_one("SELECT * FROM deliveries WHERE task_id = ? ORDER BY version DESC LIMIT 1", [deal["task_id"]])
  now = Time.now.iso8601

  DB.execute(
    <<~SQL,
      INSERT INTO acceptances
      (
        deal_id,
        delivery_id,
        accepted_by,
        acceptance_text,
        status,
        accepted_at,
        created_at,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    SQL
    [
      deal["id"],
      delivery && delivery["id"],
      params[:accepted_by].to_s.strip,
      params[:acceptance_text].to_s.strip,
      "accepted",
      now,
      now,
      now
    ]
  )

  acceptance_id = DB.last_insert_row_id

  create_deal_event(
    deal["id"],
    "acceptance_created",
    "Aceite registrado",
    "Aceite ##{acceptance_id} registrado por #{params[:accepted_by]}.",
    "acceptance_id=#{acceptance_id};delivery_id=#{delivery && delivery["id"]}"
  )

  redirect "/comercial"
end


get "/contacts" do
  @page = "contacts"

  @contacts = db_all(
    <<~SQL
      SELECT *
      FROM contacts
      ORDER BY id DESC
      LIMIT 250
    SQL
  )

  erb :contacts
end

post "/contacts" do
  now = Time.now.iso8601

  DB.execute(
    <<~SQL,
      INSERT INTO contacts
      (
        name,
        email,
        handle,
        platform,
        source_url,
        notes,
        created_at,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    SQL
    [
      params[:name].to_s.strip,
      params[:email].to_s.strip,
      params[:handle].to_s.strip,
      params[:platform].to_s.strip,
      params[:source_url].to_s.strip,
      params[:notes].to_s.strip,
      now,
      now
    ]
  )

  redirect "/contacts"
end

post "/deals/:id/contact" do
  deal = db_one("SELECT * FROM deals WHERE id = ?", [params[:id]])
  halt 404, "Deal não encontrado" unless deal

  contact_id = params[:contact_id].to_s.strip

  if contact_id.empty?
    DB.execute(
      "UPDATE deals SET contact_id = NULL, updated_at = ? WHERE id = ?",
      [Time.now.iso8601, params[:id]]
    )

    create_deal_event(
      params[:id],
      "contact_unlinked",
      "Contato removido",
      "Contato desvinculado do deal.",
      nil
    )
  else
    contact = db_one("SELECT * FROM contacts WHERE id = ?", [contact_id])
    halt 404, "Contato não encontrado" unless contact

    DB.execute(
      "UPDATE deals SET contact_id = ?, updated_at = ? WHERE id = ?",
      [contact_id, Time.now.iso8601, params[:id]]
    )

    create_deal_event(
      params[:id],
      "contact_linked",
      "Contato vinculado",
      "Contato ##{contact_id} vinculado: #{contact["name"]} #{contact["handle"]}.",
      "contact_id=#{contact_id};platform=#{contact["platform"]}"
    )
  end

  redirect "/comercial"
end


get "/deals/:id" do
  @page = "comercial"

  @deal = db_one(
    <<~SQL,
      SELECT
        deals.*,
        tasks.title AS task_title,
        tasks.source,
        tasks.url,
        proposals.title AS proposal_title,
        contacts.name AS contact_name,
        contacts.handle AS contact_handle,
        contacts.platform AS contact_platform
      FROM deals
      INNER JOIN tasks ON tasks.id = deals.task_id
      LEFT JOIN proposals ON proposals.id = deals.proposal_id
      LEFT JOIN contacts ON contacts.id = deals.contact_id
      WHERE deals.id = ?
    SQL
    [params[:id]]
  )

  halt 404, "Deal não encontrado" unless @deal

  @events = db_all(
    <<~SQL,
      SELECT *
      FROM deal_events
      WHERE deal_id = ?
      ORDER BY id DESC
      LIMIT 100
    SQL
    [params[:id]]
  )

  erb :deal_show
end
