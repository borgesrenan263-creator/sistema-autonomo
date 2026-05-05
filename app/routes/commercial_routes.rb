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

