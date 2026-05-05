module DemandClassifier
  HIGH_INTENT = [
    "bug", "error", "issue", "broken", "fix", "problem", "help",
    "feature", "request", "automation", "automate", "api",
    "integration", "transcription", "button", "ux", "performance",
    "slow", "crash", "missing", "not working"
  ]

  MONEY_WORDS = [
    "freelance", "client", "business", "payment", "checkout",
    "stripe", "automation", "workflow", "tool", "product",
    "marketplace", "saas", "crm", "dashboard"
  ]

  def self.score(item)
    text = [
      item[:title],
      item[:description],
      item[:source]
    ].compact.join(" ").downcase

    score = 3

    HIGH_INTENT.each do |word|
      score += 1 if text.include?(word)
    end

    MONEY_WORDS.each do |word|
      score += 1 if text.include?(word)
    end

    score += 1 if item[:comments].to_i >= 2
    score += 2 if item[:comments].to_i >= 5
    score += 1 if item[:points].to_i >= 20
    score += 2 if item[:points].to_i >= 100

    [[score, 10].min, 1].max
  end

  def self.stage_for(score)
    return "filtragem" if score >= 8
    return "coleta" if score >= 5

    "coleta"
  end

  def self.price_for(score)
    base = score * 45

    case score
    when 9..10
      base + rand(180..450)
    when 7..8
      base + rand(90..280)
    else
      base + rand(30..120)
    end
  end
end
