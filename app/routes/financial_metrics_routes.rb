get "/finance/metrics" do
  @page = "financial_metrics"
  @snapshot = FinancialMetricsEngine.new(DB).snapshot

  erb :financial_metrics
end

get "/finance/metrics.json" do
  content_type :json
  JSON.generate(FinancialMetricsEngine.new(DB).snapshot)
end
