require_relative "../services/concierge/autonomous_sales_policy"

get "/sales/policy" do
  @page = "sales_policy"
  @latest_sales_policy_decisions = DB.execute(
    <<~SQL
      SELECT *
      FROM concierge_decisions
      WHERE decision_type LIKE 'sales_policy_%'
      ORDER BY id DESC
      LIMIT 50
    SQL
  ).map { |r| r.reject { |k, _| k.is_a?(Integer) } }

  erb :sales_policy
end

get "/sales/policy.json" do
  content_type :json

  rows = DB.execute(
    <<~SQL
      SELECT *
      FROM concierge_decisions
      WHERE decision_type LIKE 'sales_policy_%'
      ORDER BY id DESC
      LIMIT 50
    SQL
  ).map { |r| r.reject { |k, _| k.is_a?(Integer) } }

  JSON.pretty_generate({
    generated_at: Time.now.utc.iso8601,
    decisions: rows
  })
end

post "/sales/policy/run" do
  AutonomousSalesPolicy.new(DB).run_once
  redirect "/sales/policy"
end
