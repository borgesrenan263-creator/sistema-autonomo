get "/self-repair" do
  @page = "self_repair"

  @report_path = File.expand_path("storage/logs/self_repair.log", settings.root)

  @report =
    if File.exist?(@report_path)
      File.readlines(@report_path).last(300)
    else
      ["Nenhum relatorio de auto reparo encontrado ainda."]
    end

  @summary = {
    errors: @report.count { |line| line.include?("[ERROR]") },
    warnings: @report.count { |line| line.include?("[WARN]") },
    repairs: @report.count { |line| line.include?("[REPAIR]") },
    ok: @report.count { |line| line.include?("[OK]") }
  }

  erb :self_repair
end

post "/self-repair/run" do
  output = `ruby scripts/self_repair.rb 2>&1`

  FileUtils.mkdir_p("storage/logs")

  File.open("storage/logs/self_repair_web.log", "a") do |f|
    f.puts
    f.puts "===== SELF REPAIR WEB RUN #{Time.now.iso8601} ====="
    f.puts output
  end

  redirect "/self-repair"
end
