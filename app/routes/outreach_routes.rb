get "/outreach" do
  @page = "outreach"

  @messages = db_all(
    <<~SQL
      SELECT
        outreach_messages.*,
        tasks.title AS task_title,
        contacts.name AS contact_name,
        contacts.handle AS contact_handle,
        contacts.platform AS contact_platform,
        deals.value AS deal_value
      FROM outreach_messages
      INNER JOIN tasks ON tasks.id = outreach_messages.task_id
      LEFT JOIN contacts ON contacts.id = outreach_messages.contact_id
      LEFT JOIN deals ON deals.id = outreach_messages.deal_id
      ORDER BY outreach_messages.id DESC
      LIMIT 250
    SQL
  )

  erb :outreach
end

get "/outreach/:id" do
  @page = "outreach"

  @message = db_one(
    <<~SQL,
      SELECT
        outreach_messages.*,
        tasks.title AS task_title,
        tasks.url AS task_url,
        contacts.name AS contact_name,
        contacts.handle AS contact_handle,
        contacts.platform AS contact_platform,
        deals.value AS deal_value
      FROM outreach_messages
      INNER JOIN tasks ON tasks.id = outreach_messages.task_id
      LEFT JOIN contacts ON contacts.id = outreach_messages.contact_id
      LEFT JOIN deals ON deals.id = outreach_messages.deal_id
      WHERE outreach_messages.id = ?
    SQL
    [params[:id]]
  )

  halt 404, "Mensagem não encontrada" unless @message

  @events = db_all(
    "SELECT * FROM outreach_events WHERE outreach_message_id = ? ORDER BY id DESC LIMIT 100",
    [params[:id]]
  )

  erb :outreach_show
end

post "/outreach/:id/mark-replied" do
  message = db_one("SELECT * FROM outreach_messages WHERE id = ?", [params[:id]])
  halt 404, "Mensagem não encontrada" unless message

  now = Time.now.iso8601

  DB.execute(
    "UPDATE outreach_messages SET status = 'replied', response_status = ?, replied_at = ?, updated_at = ? WHERE id = ?",
    [params[:response_status].to_s, now, now, params[:id]]
  )

  DB.execute(
    <<~SQL,
      INSERT INTO outreach_events
      (outreach_message_id, flow_id, deal_id, event_type, title, description, metadata, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    SQL
    [
      message["id"],
      message["flow_id"],
      message["deal_id"],
      "replied",
      "Resposta registrada",
      "Resposta marcada como #{params[:response_status]}.",
      "response_status=#{params[:response_status]}",
      now
    ]
  )

  if params[:response_status] == "interested"
    DB.execute("UPDATE deals SET status = 'interessado', updated_at = ? WHERE id = ?", [now, message["deal_id"]])

    DB.execute(
      "UPDATE automation_flows SET current_state = 'interested', next_action = 'create_payment', status = 'running', last_error = NULL, updated_at = ? WHERE id = ?",
      [now, message["flow_id"]]
    )
  elsif params[:response_status] == "not_interested"
    DB.execute("UPDATE deals SET status = 'perdido', updated_at = ? WHERE id = ?", [now, message["deal_id"]])

    DB.execute(
      "UPDATE automation_flows SET current_state = 'lost', next_action = NULL, status = 'lost', last_error = NULL, updated_at = ?, completed_at = ? WHERE id = ?",
      [now, now, message["flow_id"]]
    )
  end

  redirect "/outreach/#{params[:id]}"
end

