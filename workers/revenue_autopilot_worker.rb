require "net/http"
require "uri"
require "time"
require "fileutils"
require_relative "../config/database"
require_relative "../app/services/ops/ops_heartbeat"

ROOT = File.expand_path("..", __dir__)
LOG_PATH = File.join(ROOT, "storage", "logs", "revenue_autopilot.log")

FileUtils.mkdir_p(File.dirname(LOG_PATH))

BASE_URL = ENV["REVENUE_AUTOPILOT_BASE_URL"] || "http://127.0.0.1:4567"
INTERVAL = (ENV["REVENUE_AUTOPILOT_INTERVAL_SECONDS"] || "300").to_i
INTERVAL_SECONDS = INTERVAL > 0 ? INTERVAL : 300

class RevenueAutopilotWorker
  def initialize(base_url)
    @base_url = base_url
  end

  def run_once
    OpsHeartbeat.new(DB).beat(component: "revenue_autopilot", status: "ok", detail: "cycle_start") if defined?(DB)
    log("REVENUE_AUTOPILOT_CYCLE_START")

    steps.each do |step|
      run_step(step)
    end

    OpsHeartbeat.new(DB).beat(component: "revenue_autopilot", status: "ok", detail: "cycle_done") if defined?(DB)
    log("REVENUE_AUTOPILOT_CYCLE_DONE")
  rescue => e
    OpsHeartbeat.new(DB).beat(component: "revenue_autopilot", status: "error", detail: "#{e.class}: #{e.message}") if defined?(DB)
    log("REVENUE_AUTOPILOT_CYCLE_ERROR #{e.class}: #{e.message}")
  end

  private

  def steps
    [
      {
        key: "force_rescan",
        method: :post,
        path: "/force-rescan",
        critical: false,
        description: "Coletar novas oportunidades"
      },
      {
        key: "concierge_autopilot",
        method: :post,
        path: "/concierge/autopilot/run",
        critical: true,
        description: "Executar Concierge Autopilot"
      },
      {
        key: "channel_dispatch",
        method: :post,
        path: "/channels/run",
        critical: false,
        description: "Rodar dispatch de canais"
      },
      {
        key: "observability_scan",
        method: :post,
        path: "/observability/scan",
        critical: false,
        description: "Escanear observabilidade"
      }
    ]
  end

  def run_step(step)
    started = Time.now

    response = request(step[:method], step[:path])

    elapsed = (Time.now - started).round(2)

    if response
      log(
        "STEP_OK key=#{step[:key]} status=#{response.code} elapsed=#{elapsed}s description=#{step[:description]}"
      )
    else
      log(
        "STEP_NO_RESPONSE key=#{step[:key]} elapsed=#{elapsed}s description=#{step[:description]}"
      )
    end
  rescue => e
    log("STEP_ERROR key=#{step[:key]} critical=#{step[:critical]} error=#{e.class}: #{e.message}")

    raise e if step[:critical]
  end

  def request(method, path)
    uri = URI.join(@base_url, path)

    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 5
    http.read_timeout = 30

    req =
      case method
      when :post
        Net::HTTP::Post.new(uri)
      else
        Net::HTTP::Get.new(uri)
      end

    http.request(req)
  end

  def log(message)
    line = "[#{Time.now.iso8601}] #{message}"

    File.open(LOG_PATH, "a") do |f|
      f.puts line
    end

    puts line
  end
end

worker = RevenueAutopilotWorker.new(BASE_URL)

if ARGV.include?("--once")
  worker.run_once
  exit 0
end

puts "[#{Time.now.iso8601}] REVENUE_AUTOPILOT_BOOT base_url=#{BASE_URL} interval=#{INTERVAL_SECONDS}s"

loop do
  worker.run_once
  sleep INTERVAL_SECONDS
end
