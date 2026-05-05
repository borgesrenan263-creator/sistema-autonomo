require_relative "app/routes/delivery_routes"
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
require_relative "app/services/automation/automation_event_logger"
require_relative "app/services/automation/automation_engine"
require_relative "app/services/outreach/outreach_policy"
require_relative "app/services/outreach/outreach_builder"
require_relative "app/services/outreach/manual_provider"
require_relative "app/services/outreach/outreach_engine"



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

