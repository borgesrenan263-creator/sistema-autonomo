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

