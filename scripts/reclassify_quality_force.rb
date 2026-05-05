require "sqlite3"

DB_PATH = File.expand_path("../data/sistema_autonomo.sqlite3", __dir__)

db = SQLite3::Database.new(DB_PATH)
db.results_as_hash = true

rows = db.execute("SELECT id, title, description, source, status FROM tasks")

blocklist = [
  "cve",
  "vulnerability",
  "vulnerable",
  "exploit",
  "rce",
  "xss",
  "csrf",
  "credential",
  "token leak",
  "security bypass",
  "malware",
  "phishing",
  "backdoor"
]

weak = [
  "discuss:",
  "show hn",
  "ask hn",
  "is out",
  "commits to",
  "announces",
  "launches",
  "opinion",
  "essay",
  "takeover offer",
  "policy"
]

strong = [
  "$",
  "bounty",
  "bug",
  "broken",
  "not working",
  "error",
  "crash",
  "crashing",
  "can't",
  "cannot",
  "failed",
  "fails",
  "missing",
  "button",
  "dropdown",
  "integration",
  "api",
  "dashboard",
  "checkout",
  "stripe",
  "receipt",
  "expense",
  "invoice",
  "automation",
  "workflow",
  "storybook",
  "build broken",
  "copy button"
]

counts = Hash.new(0)

rows.each do |row|
  title = row["title"].to_s
  text = [
    row["title"],
    row["description"],
    row["source"]
  ].compact.join(" ").downcase

  quality_status = "review"
  quality_reason = "unclear_signal"

  if title.downcase.start_with?("discuss:")
    quality_status = "ignore"
    quality_reason = "discussion_not_microservice"
  elsif blocklist.any? { |w| text.include?(w) }
    quality_status = "ignore"
    quality_reason = "security_sensitive"
  else
    strong_hits = strong.count { |w| text.include?(w) }
    weak_hits = weak.count { |w| text.include?(w) }

    if weak_hits >= 1 && strong_hits < 3
      quality_status = "ignore"
      quality_reason = "weak_or_news_signal"
    elsif strong_hits >= 2
      quality_status = "monetizable"
      quality_reason = "strong_commercial_signal"
    elsif strong_hits == 1 && weak_hits == 0
      quality_status = "monetizable"
      quality_reason = "single_clear_pain_signal"
    else
      quality_status = "review"
      quality_reason = "unclear_signal"
    end
  end

  score = 5

  strong.each do |w|
    score += 1 if text.include?(w)
  end

  if quality_status == "ignore"
    score = [score - 5, 1].max
  elsif quality_status == "review"
    score = [score - 2, 1].max
  end

  score = [[score, 10].min, 1].max

  price =
    if quality_status == "ignore"
      0
    elsif quality_status == "monetizable"
      100 + (score * 70)
    else
      50 + (score * 35)
    end

  stage =
    if row["status"] == "ok"
      "historico"
    elsif row["status"] == "faturamento"
      "faturamento"
    elsif quality_status == "monetizable"
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
    "UPDATE tasks SET quality_status = ?, quality_reason = ?, demand_score = ?, suggested_price = ?, stage = ?, status = ? WHERE id = ?",
    [quality_status, quality_reason, score, price, stage, status, row["id"]]
  )

  counts[quality_status] += 1
end

puts "Reclassificação forçada concluída."
counts.sort.each do |key, value|
  puts "#{key}: #{value}"
end
