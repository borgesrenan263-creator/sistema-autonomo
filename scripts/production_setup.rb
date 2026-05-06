require "fileutils"
require_relative "../config/env_guard"

ROOT = File.expand_path("..", __dir__)

puts "SISTEMA AUTONOMO — PRODUCTION SETUP"
puts "==================================="

puts "RACK_ENV=#{ENV["RACK_ENV"]}"
puts "APP_ENV=#{ENV["APP_ENV"]}"
puts "DATABASE_URL=#{ENV["DATABASE_URL"].to_s.empty? ? "missing" : "configured"}"

required_dirs = [
  "storage",
  "storage/logs",
  "storage/exports",
  "storage/tmp",
  "storage/exports/validation"
]

required_dirs.each do |dir|
  path = File.join(ROOT, dir)
  FileUtils.mkdir_p(path)
  puts "DIR OK: #{path}"
end

migration_files = Dir[File.join(ROOT, "db", "*.rb")].sort

migration_files.each do |file|
  puts "RUN MIGRATION: #{File.basename(file)}"
  system("ruby #{file}")
end

puts "Production setup done."
