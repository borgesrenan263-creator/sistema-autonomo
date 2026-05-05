module QualityGate
  SECURITY_BLOCKLIST = [
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
    "backdoor",
    "exposed military data",
    "leaked",
    "data breach"
  ]

  HARD_WEAK = [
    "discuss:",
    "rfc:",
    "show hn",
    "ask hn",
    "launch hn",
    "is out",
    "commits to",
    "announces",
    "launches",
    "takeover offer",
    "working group",
    "market diagnostic",
    "opinion",
    "essay",
    "study:",
    "researchers",
    "we found exposed",
    "sued for",
    "biases to manipulate",
    "bad at software architecture"
  ]

  SOFT_WEAK = [
    "platform market",
    "new way to",
    "fast npm package manager",
    "digital wardrobe",
    "days without",
    "llm hallucinations",
    "visa pathways",
    "quiz",
    "trust layer"
  ]

  STRONG_PAIN = [
    "$",
    "bounty",
    "bug",
    "bug report",
    "broken",
    "not working",
    "isn't working",
    "doesn't work",
    "error",
    "crash",
    "crashing",
    "failed",
    "fails",
    "failure",
    "unable",
    "can't",
    "cannot",
    "missing",
    "not shown",
    "does not match",
    "incorrect",
    "wrong",
    "regression",
    "race",
    "leak",
    "build broken",
    "test failing",
    "storybook",
    "dropdown",
    "button",
    "receipt",
    "expense",
    "invoice",
    "checkout",
    "stripe",
    "custom storage",
    "workspace context"
  ]

  TECH_VALUE = [
    "api",
    "integration",
    "dashboard",
    "automation",
    "workflow",
    "ci",
    "build",
    "dev",
    "runtime",
    "package",
    "storage",
    "database",
    "state.db",
    "performance",
    "startup",
    "metrics",
    "streaming"
  ]

  def self.evaluate(item)
    title = item[:title].to_s
    description = item[:description].to_s
    source = item[:source].to_s

    text = [title, description, source].join(" ").downcase
    title_down = title.downcase

    if SECURITY_BLOCKLIST.any? { |word| text.include?(word) }
      return {
        status: "ignore",
        reason: "security_sensitive"
      }
    end

    if title_down.start_with?("discuss:") || title_down.start_with?("rfc:")
      return {
        status: "ignore",
        reason: "discussion_or_rfc"
      }
    end

    hard_weak_hits = HARD_WEAK.count { |word| text.include?(word) }
    soft_weak_hits = SOFT_WEAK.count { |word| text.include?(word) }
    pain_hits = STRONG_PAIN.count { |word| text.include?(word) }
    tech_hits = TECH_VALUE.count { |word| text.include?(word) }

    # Notícias/posts amplos só entram em review se tiverem algum sinal técnico,
    # nunca como monetizable direto.
    if hard_weak_hits >= 1 && pain_hits < 2
      return {
        status: "ignore",
        reason: "weak_or_news_signal"
      }
    end

    if soft_weak_hits >= 1 && pain_hits == 0
      return {
        status: "review",
        reason: "interesting_but_not_actionable"
      }
    end

    # Bounty explícito ou preço em issue costuma ser forte.
    if title.include?("$") && pain_hits >= 1
      return {
        status: "monetizable",
        reason: "bounty_or_paid_issue"
      }
    end

    # Dor técnica clara + contexto técnico.
    if pain_hits >= 2
      return {
        status: "monetizable",
        reason: "clear_reproducible_pain"
      }
    end

    if pain_hits >= 1 && tech_hits >= 1
      return {
        status: "monetizable",
        reason: "technical_pain_with_context"
      }
    end

    if pain_hits == 1
      return {
        status: "review",
        reason: "single_pain_signal_needs_review"
      }
    end

    if tech_hits >= 2
      return {
        status: "review",
        reason: "technical_interest_without_clear_pain"
      }
    end

    {
      status: "review",
      reason: "unclear_signal"
    }
  end
end
