get "/historico" do
  @page = "historico"
  @tasks = tasks
  @completed_tasks = completed_tasks
  @stats = system_stats
  erb :historico
end

get "/manifesto" do
  @page = "manifesto"
  @stats = system_stats
  erb :manifesto
end

