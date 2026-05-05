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

