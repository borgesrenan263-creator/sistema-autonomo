require "date"
require "time"

class FinancialMetricsEngine
  def initialize(db)
    @db = db
  end

  def snapshot
    payments = all("SELECT * FROM payments ORDER BY id DESC")
    deals = all("SELECT * FROM deals ORDER BY id DESC")
    tasks = all("SELECT * FROM tasks ORDER BY id DESC")

    paid_payments = payments.select { |p| p["status"].to_s == "paid" }
    pending_payments = payments.select { |p| p["status"].to_s == "pending" }

    {
      generated_at: Time.now.iso8601,
      totals: {
        payments_count: payments.count,
        paid_count: paid_payments.count,
        pending_count: pending_payments.count,
        deals_count: deals.count,
        tasks_count: tasks.count,
        revenue_paid: sum_amount(paid_payments),
        revenue_pending: sum_amount(pending_payments),
        revenue_total_pipeline: sum_amount(payments),
        average_ticket: average_amount(paid_payments),
        conversion_payment_rate: percent(paid_payments.count, payments.count),
        conversion_deal_paid_rate: percent(paid_payments.map { |p| p["deal_id"] }.compact.uniq.count, deals.count)
      },
      payments_by_status: group_count(payments, "status"),
      deals_by_status: group_count(deals, "status"),
      tasks_by_status: group_count(tasks, "status"),
      revenue_by_day: revenue_by_day(paid_payments),
      pending_by_day: revenue_by_day(pending_payments),
      revenue_by_provider: revenue_by_provider(payments),
      revenue_by_deal_status: revenue_by_deal_status(payments, deals),
      latest_paid: paid_payments.first(10),
      latest_pending: pending_payments.first(10),
      warnings: warnings(payments, deals, tasks)
    }
  end

  private

  def sum_amount(rows)
    rows.sum { |row| money(row["amount"] || row["value"] || 0) }
  end

  def average_amount(rows)
    return 0 if rows.empty?

    (sum_amount(rows).to_f / rows.count).round(2)
  end

  def money(value)
    value.to_s.gsub(/[^\d.,-]/, "").tr(",", ".").to_f
  end

  def percent(part, total)
    return 0 if total.to_i <= 0

    ((part.to_f / total.to_f) * 100).round(2)
  end

  def group_count(rows, key)
    grouped = Hash.new(0)

    rows.each do |row|
      value = row[key].to_s
      value = "unknown" if value.empty?
      grouped[value] += 1
    end

    grouped.sort_by { |_k, v| -v }.to_h
  end

  def revenue_by_day(rows)
    grouped = Hash.new(0.0)

    rows.each do |row|
      date = extract_date(row["paid_at"] || row["created_at"] || row["updated_at"])
      grouped[date] += money(row["amount"] || row["value"] || 0)
    end

    grouped
      .sort_by { |date, _amount| date }
      .last(30)
      .to_h
  end

  def revenue_by_provider(rows)
    grouped = Hash.new(0.0)

    rows.each do |row|
      provider = row["provider"].to_s
      provider = row["method"].to_s if provider.empty?
      provider = "unknown" if provider.empty?
      grouped[provider] += money(row["amount"] || row["value"] || 0)
    end

    grouped.sort_by { |_k, v| -v }.to_h
  end

  def revenue_by_deal_status(payments, deals)
    deals_by_id = deals.each_with_object({}) { |d, h| h[d["id"].to_s] = d }
    grouped = Hash.new(0.0)

    payments.each do |payment|
      deal = deals_by_id[payment["deal_id"].to_s]
      status = deal ? deal["status"].to_s : "unknown"
      status = "unknown" if status.empty?
      grouped[status] += money(payment["amount"] || payment["value"] || 0)
    end

    grouped.sort_by { |_k, v| -v }.to_h
  end

  def extract_date(value)
    return Date.today.to_s if value.to_s.empty?

    Time.parse(value.to_s).to_date.to_s
  rescue
    Date.today.to_s
  end

  def warnings(payments, deals, tasks)
    list = []

    pending = payments.select { |p| p["status"].to_s == "pending" }
    list << "#{pending.count} pagamento(s) pendente(s)." if pending.any?

    failed = payments.select { |p| p["status"].to_s == "failed" }
    list << "#{failed.count} pagamento(s) com falha." if failed.any?

    open_deals = deals.select { |d| ["aberto", "interessado", "open", "pending"].include?(d["status"].to_s) }
    list << "#{open_deals.count} deal(s) ainda aberto(s)." if open_deals.any?

    unpriced = deals.select { |d| money(d["value"] || 0) <= 0 }
    list << "#{unpriced.count} deal(s) sem valor definido." if unpriced.any?

    if tasks.empty?
      list << "Nenhuma task encontrada."
    end

    list
  end

  def all(sql, params = [])
    @db.execute(sql, params).map { |row| row.reject { |k, _| k.is_a?(Integer) } }
  end
end
