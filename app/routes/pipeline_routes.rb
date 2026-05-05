get "/pipeline" do
  @page = "pipeline"
  @tasks = tasks
  @stats = system_stats
  erb :pipeline
end

post "/force-rescan" do
  result = RealRescan.new(DB).call
  redirect "/pipeline?inserted=#{result[:inserted]}&skipped=#{result[:skipped]}&total=#{result[:total]}"
end

