require "sqlite3"
require_relative "../app/services/filters/quality_gate"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)

db = SQLite3::Database.new(DB_PATH)
db.results_as_hash = true

rows = db.execute("SELECT id, title, description, source, status FROM tasks")

counts = Hash.new(0)
reasons = Hash.new(0)

rows.each do |row|
  item = {
    title: row["title"].to_s,
    description: row["description"].to_s,
    source: row["source"].to_s
  }

  gate = QualityGate.evaluate(item)

  text = [
    row["title"],
    row["description"],
    row["source"]
  ].compact.join(" ").downcase

  score = 3

  pain_words = [
    "$", "bounty", "bug", "broken", "not working", "isn't working",
    "error", "crash", "crashing", "failed", "fails", "unable",
    "can't", "cannot", "missing", "incorrect", "wrong", "regression",
    "race", "build broken", "test failing", "storybook", "dropdown",
    "button", "receipt", "expense", "invoice", "checkout", "stripe",
    "streaming", "custom storage"
  ]

  tech_words = [
    "api", "integration", "dashboard", "automation", "workflow",
    "ci", "build", "dev", "runtime", "package", "storage",
    "database", "performance", "startup", "metrics"
  ]

  pain_words.each { |w| score += 1 if text.include?(w) }
  tech_words.each { |w| score += 1 if text.include?(w) }

  case gate[:status]
  when "monetizable"
    score = [[score, 10].min, 6].max
  when "review"
    score = [[score, 7].min, 1].max
  when "ignore"
    score = [[score - 5, 3].min, 1].max
  end

  price =
    case gate[:status]
    when "monetizable"
      120 + (score * 75)
    when "review"
      40 + (score * 30)
    else
      0
    end

  stage =
    if row["status"] == "ok"
      "historico"
    elsif row["status"] == "faturamento"
      "faturamento"
    elsif gate[:status] == "monetizable"
      "filtragem"
    else
      "coleta"
    end

  status =
    if row["status"] == "ok"
      "ok"
    elsif row["status"] == "faturamento"
      "faturamento"
    else
      stage
    end

  db.execute(
    <<~SQL,
      UPDATE tasks
      SET quality_status = ?,
          quality_reason = ?,
          demand_score = ?,
          suggested_price = ?,
          stage = ?,
          status = ?
      WHERE id = ?
    SQL
    [
      gate[:status],
      gate[:reason],
      score,
      price,
      stage,
      status,
      row["id"]
    ]
  )

  counts[gate[:status]] += 1
  reasons["#{gate[:status]}|#{gate[:reason]}"] += 1
end

puts "Quality Gate v2 aplicado."
puts
puts "STATUS:"
counts.sort.each { |k, v| puts "#{k}: #{v}" }

puts
puts "REASONS:"
reasons.sort.each { |k, v| puts "#{k}: #{v}" }
