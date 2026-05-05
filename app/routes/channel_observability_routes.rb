get "/channels" do
  @page = "channels"

  @dispatches = db_all(
    <<~SQL
      SELECT *
      FROM channel_dispatches
      ORDER BY id DESC
      LIMIT 200
    SQL
  )

  erb :channels
end

post "/channels/sync" do
  ChannelDispatchEngine.new(DB).sync_outbox
  redirect "/channels"
end

post "/channels/run" do
  ChannelDispatchEngine.new(DB).run_once
  redirect "/channels"
end

post "/channels/test-dispatch" do
  now = Time.now.iso8601

  flow = db_one("SELECT * FROM automation_flows ORDER BY id DESC LIMIT 1")
  halt 400, "Nenhum flow encontrado" unless flow

  deal_id = flow["deal_id"]
  task_id = flow["task_id"]

  contact = db_one("SELECT * FROM contacts ORDER BY id DESC LIMIT 1")
  halt 400, "Nenhum contato encontrado" unless contact

  deal =
    if deal_id
      db_one("SELECT * FROM deals WHERE id = ?", [deal_id])
    else
      db_one("SELECT * FROM deals WHERE task_id = ? ORDER BY id DESC LIMIT 1", [task_id])
    end

  subject = "Teste controlado de dispatch — Sistema Autônomo"

  body = [
    "Olá, #{contact["name"] || "contato"}.",
    "",
    "Esta é uma mensagem de teste do Channel Dispatch em modo manual_channel.",
    "Nenhum envio externo real foi feito.",
    "",
    "Flow: #{flow["id"]}",
    "Deal: #{deal ? deal["id"] : "-"}",
    "Task: #{task_id}"
  ].join("
")

  DB.execute(
    <<~SQL,
      INSERT INTO outreach_messages
      (
        flow_id,
        deal_id,
        contact_id,
        provider,
        subject,
        message_body,
        status,
        policy_status,
        policy_reason,
        created_at,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL
    [
      flow["id"],
      deal ? deal["id"] : deal_id,
      contact["id"],
      "manual_provider",
      subject,
      body,
      "queued",
      "approved",
      "test_dispatch_allowed",
      now,
      now
    ]
  )

  outreach_id = DB.last_insert_row_id

  ChannelDispatchEngine.new(DB).run_once

  redirect "/channels"
end
get "/observability" do
  @page = "observability"

  @signals = db_all(
    <<~SQL
      SELECT *
      FROM observability_signals
      ORDER BY
        CASE status
          WHEN 'open' THEN 1
          ELSE 2
        END,
        id DESC
      LIMIT 300
    SQL
  )

  erb :observability
end

post "/observability/scan" do
  ObservabilityEngine.new(DB).scan
  redirect "/observability"
end
