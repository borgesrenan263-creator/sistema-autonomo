root = File.expand_path("..", __dir__)

paths = {
  "app.rb" => File.join(root, "app.rb"),
  "config/database.rb" => File.join(root, "config/database.rb"),
  "app/core/bootstrap.rb" => File.join(root, "app/core/bootstrap.rb"),
  "app/core/database_helpers.rb" => File.join(root, "app/core/database_helpers.rb"),
  "app/routes" => File.join(root, "app/routes"),
  "app/repositories" => File.join(root, "app/repositories"),
  "app/services" => File.join(root, "app/services"),
  "app/views" => File.join(root, "app/views"),
  "workers" => File.join(root, "workers"),
  "docs/ARCHITECTURE.md" => File.join(root, "docs/ARCHITECTURE.md")
}

puts "SISTEMA AUTONOMO — ARCHITECTURE AUDIT"
puts "===================================="

paths.each do |label, path|
  status = File.exist?(path) || Dir.exist?(path) ? "OK" : "MISSING"
  puts "#{status.ljust(8)} #{label}"
end

app_rb = File.join(root, "app.rb")

if File.exist?(app_rb)
  lines = File.readlines(app_rb).count
  puts
  puts "app.rb lines: #{lines}"

  if lines > 700
    puts "WARN: app.rb ainda esta grande. Proximo passo: mover rotas para app/routes."
  else
    puts "OK: app.rb em tamanho aceitavel."
  end
end
