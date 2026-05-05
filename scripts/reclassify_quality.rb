require "sqlite3"
require_relative "../app/services/filters/demand_classifier"
require_relative "../app/services/filters/quality_gate"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)

db = SQLite3::Database.new(DB_PATH)
db.results_as_hash = true

columns = db.execute("PRAGMA table_info(tasks)").map { |row| row[1] }

unless columns.include?("quality_status")
  db.execute "ALTER TABLE tasks ADD COLUMN quality_status TEXT DEFAULT 'review';"
end

unless columns.include?("quality_reason")
  db.execute "ALTER TABLE tasks ADD COLUMN quality_reason TEXT DEFAULT 'not_evaluated';"
end

rows = db.execute("SELECT * FROM tasks")

counts = Hash.new(0)

rows.each do |task|
  item = {
    title: task["title"].to_s,
    description: task["description"].to_s,
    source: task["source"].to_s,
    comments: 0,
    points: 0
  }

  gate = QualityGate.evaluate(item)
  score = DemandClassifier.score(item)

  if gate[:status] == "ignore"
    score = [score - 6, 1].max
  elsif gate[:status] == "review"
    score = [score - 2, 1].max
  end

  stage =
    if task["status"] == "ok"
      "historico"
    elsif task["status"] == "faturamento"
      "faturamento"
    elsif gate[:status] == "monetizable" && score >= 6
      "filtragem"
    else
      "coleta"
    end

  status =
    if task["status"] == "ok"
      "ok"
    elsif task["status"] == "faturamento"
      "faturamento"
    else
      stage
    end

  price = DemandClassifier.price_for(score)

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
      task["id"]
    ]
  )

  counts[gate[:status]] += 1
end

puts "Reclassificação concluída."
puts counts.sort.map { |k, v| "#{k}: #{v}" }.join("\n")
