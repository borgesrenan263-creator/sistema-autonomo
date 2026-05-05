require "json"
require "time"
require "openssl"

class PixPaymentProvider
  def initialize(db)
    @db = db
  end

  def handle_webhook(raw_body:, headers: {})
    payload = parse_json(raw_body)
    secret_ok = valid_secret?(headers)

    event_id = value(payload, "event_id") || value(payload, "id") || value(payload, "endToEndId")
    txid = value(payload, "txid") || value(payload, "tx_id")
    reference = value(payload, "reference") || value(payload, "ref") || value(payload, "payment_reference")
    status = normalize_status(value(payload, "status") || value(payload, "payment_status"))
    amount = normalize_amount(value(payload, "amount") || value(payload, "valor"))

    event = register_event(
      event_id: event_id,
      txid: txid,
      reference: reference,
      status: status,
      amount: amount,
      raw_body: raw_body,
      signature_valid: secret_ok ? 1 : 0
    )

    unless secret_ok
      mark_event_error(event["id"], "invalid_webhook_secret")
      return { ok: false, status: 401, message: "invalid_webhook_secret" }
    end

    if event_already_processed?(event)
      return { ok: true, status: 200, message: "already_processed", event_id: event["id"] }
    end

    unless paid_status?(status)
      mark_event_error(event["id"], "ignored_status_#{status}")
      return { ok: true, status: 200, message: "ignored_status_#{status}", event_id: event["id"] }
    end

    payment = find_payment(reference: reference, txid: txid, amount: amount)

    unless payment
      mark_event_error(event["id"], "payment_not_found")
      return { ok: false, status: 404, message: "payment_not_found", event_id: event["id"] }
    end

    mark_payment_paid(payment, payload, txid, reference)
    mark_event_processed(event["id"], payment)

    advance_flow_after_payment(payment)
    notify_payment_completed(payment)

    { ok: true, status: 200, message: "payment_paid", payment_id: payment["id"], event_id: event["id"] }
  rescue => e
    { ok: false, status: 500, message: "#{e.class}: #{e.message}" }
  end

  private

  def parse_json(raw_body)
    JSON.parse(raw_body.to_s.empty? ? "{}" : raw_body)
  rescue JSON::ParserError
    {}
  end

  def value(payload, key)
    payload[key] || payload[key.to_sym]
  end

  def valid_secret?(headers)
    expected =
      if defined?(AppSettings)
        AppSettings.get("PIX_WEBHOOK_SECRET").to_s
      else
        ENV["PIX_WEBHOOK_SECRET"].to_s
      end

    return false if expected.empty?
    return false if expected == "trocar_em_producao"

    received =
      headers["HTTP_X_PIX_SECRET"] ||
      headers["X-PIX-SECRET"] ||
      headers["x-pix-secret"]

    secure_compare(expected, received.to_s)
  end

  def secure_compare(a, b)
    return false if a.bytesize != b.bytesize

    OpenSSL.fixed_length_secure_compare(a, b)
  rescue
    a == b
  end

  def normalize_status(status)
    status.to_s.downcase.strip
  end

  def paid_status?(status)
    ["paid", "approved", "confirmed", "completed", "liquidado", "pago"].include?(status.to_s)
  end

  def normalize_amount(amount)
    return nil if amount.nil?

    if amount.is_a?(Integer)
      amount
    elsif amount.is_a?(Float)
      amount.round
    else
      text = amount.to_s.tr(",", ".")
      text.to_f.round
    end
  end

  def register_event(event_id:, txid:, reference:, status:, amount:, raw_body:, signature_valid:)
    now = Time.now.iso8601

    existing =
      if event_id && !event_id.to_s.empty?
        one("SELECT * FROM pix_webhook_events WHERE event_id = ? ORDER BY id DESC LIMIT 1", [event_id])
      end

    return existing if existing

    @db.execute(
      <<~SQL,
        INSERT INTO pix_webhook_events
        (
          event_id,
          txid,
          reference,
          provider,
          status,
          amount,
          raw_body,
          signature_valid,
          processed,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        event_id,
        txid,
        reference,
        "generic_pix",
        status,
        amount,
        raw_body,
        signature_valid,
        0,
        now
      ]
    )

    one("SELECT * FROM pix_webhook_events WHERE id = ?", [@db.last_insert_row_id])
  end

  def event_already_processed?(event)
    event && event["processed"].to_i == 1
  end

  def find_payment(reference:, txid:, amount:)
    candidates = []

    if reference && !reference.to_s.empty?
      candidates << one("SELECT * FROM payments WHERE reference = ? ORDER BY id DESC LIMIT 1", [reference])
      candidates << one("SELECT * FROM payments WHERE external_reference = ? ORDER BY id DESC LIMIT 1", [reference])
    end

    if txid && !txid.to_s.empty?
      candidates << one("SELECT * FROM payments WHERE txid = ? ORDER BY id DESC LIMIT 1", [txid])
    end

    candidates.compact.first || find_pending_by_amount(amount)
  end

  def find_pending_by_amount(amount)
    return nil unless amount

    one(
      <<~SQL,
        SELECT *
        FROM payments
        WHERE status = 'pending'
          AND amount = ?
        ORDER BY id DESC
        LIMIT 1
      SQL
      [amount]
    )
  end

  def mark_payment_paid(payment, payload, txid, reference)
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        UPDATE payments
        SET status = 'paid',
            paid_at = COALESCE(paid_at, ?),
            updated_at = ?,
            provider = 'pix_webhook',
            txid = COALESCE(txid, ?),
            external_reference = COALESCE(external_reference, ?),
            provider_payload = ?
        WHERE id = ?
      SQL
      [
        now,
        now,
        txid,
        reference,
        JSON.generate(payload),
        payment["id"]
      ]
    )

    @db.execute(
      "UPDATE tasks SET status = 'ok', stage = 'historico', paid_at = COALESCE(paid_at, ?), updated_at = ? WHERE id = ?",
      [now, now, payment["task_id"]]
    )

    @db.execute(
      "UPDATE deals SET status = 'fechado', updated_at = ? WHERE id = ?",
      [now, payment["deal_id"]]
    )
  end

  def advance_flow_after_payment(payment)
    flow = one(
      "SELECT * FROM automation_flows WHERE deal_id = ? ORDER BY id DESC LIMIT 1",
      [payment["deal_id"]]
    )

    return unless flow

    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        UPDATE automation_flows
        SET current_state = 'payment_paid',
            next_action = 'complete_flow',
            status = 'running',
            last_error = NULL,
            updated_at = ?
        WHERE id = ?
      SQL
      [now, flow["id"]]
    )

    if defined?(ConciergeAutopilot)
      ConciergeAutopilot.new(@db).run_once
    elsif defined?(AutomationEngine)
      AutomationEngine.new(@db).run_next(flow["id"])
    end
  end

  def notify_payment_completed(payment)
    return unless defined?(SystemNotifier)

    SystemNotifier.new(@db).notify(
      kind: "payment_completed",
      title: "Pagamento Pix confirmado",
      body: "Pagamento ##{payment["id"]} confirmado via webhook Pix.",
      link: "/financeiro",
      dedupe_key: "pix_payment_completed_#{payment["id"]}"
    )
  end

  def mark_event_processed(event_id, payment)
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        UPDATE pix_webhook_events
        SET processed = 1,
            processing_error = NULL,
            payment_id = ?,
            deal_id = ?,
            task_id = ?,
            processed_at = ?
        WHERE id = ?
      SQL
      [
        payment["id"],
        payment["deal_id"],
        payment["task_id"],
        now,
        event_id
      ]
    )
  end

  def mark_event_error(event_id, error)
    @db.execute(
      "UPDATE pix_webhook_events SET processing_error = ? WHERE id = ?",
      [error, event_id]
    )
  end

  def one(sql, params = [])
    row = @db.get_first_row(sql, params)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
