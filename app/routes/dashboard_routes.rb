get "/" do
  @page = "dashboard"
  @tasks = tasks
  @stats = system_stats
  erb :dashboard
end

