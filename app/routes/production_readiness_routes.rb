require_relative "../services/ops/production_readiness_engine"

get "/ops/production-readiness" do
  @page = "production_readiness"
  @readiness = ProductionReadinessEngine.new(DB).snapshot

  erb :production_readiness
end

get "/ops/production-readiness.json" do
  content_type :json

  JSON.pretty_generate(ProductionReadinessEngine.new(DB).snapshot)
end
