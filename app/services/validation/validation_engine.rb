require "time"
require "fileutils"

class ValidationEngine
  MIN_VALID_SCORE = 70

  STACK_PATTERNS = {
    "ruby" => [/ruby/i, /sinatra/i, /rails/i, /gemfile/i],
    "javascript" => [/node/i, /npm/i, /vite/i, /react/i, /package\.json/i],
    "python" => [/python/i, /django/i, /flask/i, /requirements\.txt/i],
    "php" => [/php/i, /wordpress/i, /laravel/i],
    "database" => [/sqlite/i, /postgres/i, /mysql/i, /sql/i],
    "frontend" => [/html/i, /css/i, /javascript/i, /react/i, /tailwind/i]
  }

  REQUIRED_CONTENT_PATTERNS = [
    /problema/i,
    /diagn/i,
    /solu/i,
    /passo/i,
    /teste/i,
    /risco/i,
    /comando/i
  ]

  DANGEROUS_PATTERNS = [
    /rm\s+-rf/i,
    /curl\s+.*\|\s*(sh|bash)/i,
    /wget\s+.*\|\s*(sh|bash)/i,
    /chmod\s+777/i,
    /sudo\s+/i,
    /format\s+c:/i,
    /DROP\s+DATABASE/i,
    /delete\s+from\s+\w+\s*;/i
  ]

  def initialize(db)
    @db = db
  end

  def validate_delivery(delivery_id)
    delivery = one("SELECT * FROM deliveries WHERE id = ?", [delivery_id])
    raise "Delivery não encontrada" unless delivery

    task = one("SELECT * FROM tasks WHERE id = ?", [delivery["task_id"]])

    now = Time.now.iso8601
    content = extract_content(delivery)

    stack = detect_stack(content, task)
    findings = build_findings(content, task, stack)
    score = calculate_score(findings)
    status = score >= MIN_VALID_SCORE ? "validated" : "manual_review"

    evidence_path = write_evidence(delivery, task, stack, findings, score, status)

    @db.execute(
      <<~SQL,
        INSERT INTO validation_runs
        (
          delivery_id,
          task_id,
          status,
          score,
          stack_detected,
          summary,
          evidence_path,
          findings,
          created_at,
          completed_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        delivery["id"],
        delivery["task_id"],
        status,
        score,
        stack,
        findings[:summary],
        evidence_path,
        serialize_findings(findings),
        now,
        now
      ]
    )

    @db.execute(
      <<~SQL,
        UPDATE deliveries
        SET validation_status = ?,
            validation_score = ?,
            validated_at = ?
        WHERE id = ?
      SQL
      [status, score, now, delivery["id"]]
    )

    create_observability_signal(delivery, status, score) if status != "validated"
    notify(delivery, status, score)

    one("SELECT * FROM validation_runs WHERE id = ?", [@db.last_insert_row_id])
  rescue => e
    register_failure(delivery_id, e)
    raise e
  end

  def validate_latest(limit = 20)
    deliveries = all(
      <<~SQL,
        SELECT *
        FROM deliveries
        WHERE validation_status IS NULL
           OR validation_status = ''
           OR validation_status = 'manual_review'
        ORDER BY id DESC
        LIMIT ?
      SQL
      [limit]
    )

    deliveries.map do |delivery|
      begin
        validate_delivery(delivery["id"])
      rescue => e
        { "delivery_id" => delivery["id"], "error" => e.message }
      end
    end
  end

  private

  def extract_content(delivery)
    [
      delivery["title"],
      delivery["content"],
      delivery["body"],
      delivery["result"],
      delivery["notes"]
    ].compact.join("\n\n")
  end

  def detect_stack(content, task)
    text = [
      content,
      task && task["title"],
      task && task["source"],
      task && task["url"]
    ].compact.join(" ")

    matched = STACK_PATTERNS.select do |_stack, patterns|
      patterns.any? { |pattern| text.match?(pattern) }
    end.keys

    matched.empty? ? "unknown" : matched.join(",")
  end

  def build_findings(content, task, stack)
    findings = {
      summary: "",
      positives: [],
      warnings: [],
      blockers: []
    }

    if content.length > 800
      findings[:positives] << "Entrega possui conteúdo substancial."
    else
      findings[:warnings] << "Entrega curta demais para validação forte."
    end

    REQUIRED_CONTENT_PATTERNS.each do |pattern|
      if content.match?(pattern)
        findings[:positives] << "Encontrado critério: #{pattern.source}"
      else
        findings[:warnings] << "Critério ausente: #{pattern.source}"
      end
    end

    DANGEROUS_PATTERNS.each do |pattern|
      if content.match?(pattern)
        findings[:blockers] << "Padrão perigoso encontrado: #{pattern.source}"
      end
    end

    if stack == "unknown"
      findings[:warnings] << "Stack não detectada."
    else
      findings[:positives] << "Stack detectada: #{stack}."
    end

    if task && task["quality_status"].to_s == "monetizable"
      findings[:positives] << "Task classificada como monetizable."
    else
      findings[:warnings] << "Task não está marcada como monetizable."
    end

    findings[:summary] =
      if findings[:blockers].any?
        "Validação encontrou bloqueadores críticos."
      elsif findings[:warnings].count > findings[:positives].count
        "Validação recomenda revisão manual."
      else
        "Entrega validada por checklist estático."
      end

    findings
  end

  def calculate_score(findings)
    score = 50
    score += findings[:positives].count * 7
    score -= findings[:warnings].count * 5
    score -= findings[:blockers].count * 30

    [[score, 0].max, 100].min
  end

  def write_evidence(delivery, task, stack, findings, score, status)
    dir = File.join(File.expand_path("../../..", __dir__), "storage", "exports", "validation")
    FileUtils.mkdir_p(dir)

    path = File.join(dir, "delivery-#{delivery["id"]}-validation.txt")

    File.write(path, <<~TXT)
      SISTEMA AUTONOMO — VALIDATION REPORT
      ===================================

      Delivery ID: #{delivery["id"]}
      Task ID: #{delivery["task_id"]}
      Status: #{status}
      Score: #{score}
      Stack: #{stack}
      Generated at: #{Time.now.iso8601}

      SUMMARY
      -------
      #{findings[:summary]}

      POSITIVES
      ---------
      #{findings[:positives].map { |x| "- #{x}" }.join("\n")}

      WARNINGS
      --------
      #{findings[:warnings].map { |x| "- #{x}" }.join("\n")}

      BLOCKERS
      --------
      #{findings[:blockers].map { |x| "- #{x}" }.join("\n")}
    TXT

    path
  end

  def serialize_findings(findings)
    [
      "summary=#{findings[:summary]}",
      "positives=#{findings[:positives].join(' | ')}",
      "warnings=#{findings[:warnings].join(' | ')}",
      "blockers=#{findings[:blockers].join(' | ')}"
    ].join("\n")
  end

  def create_observability_signal(delivery, status, score)
    return unless table_exists?("observability_signals")

    existing = one(
      <<~SQL,
        SELECT *
        FROM observability_signals
        WHERE signal_type = 'validation_review'
          AND entity_type = 'delivery'
          AND entity_id = ?
          AND status = 'open'
        LIMIT 1
      SQL
      [delivery["id"]]
    )

    return if existing

    @db.execute(
      <<~SQL,
        INSERT INTO observability_signals
        (
          signal_type,
          entity_type,
          entity_id,
          task_id,
          severity,
          status,
          title,
          detail,
          link,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        "validation_review",
        "delivery",
        delivery["id"],
        delivery["task_id"],
        "warning",
        "open",
        "Entrega precisa de revisão manual",
        "Validation score #{score}, status #{status}.",
        "/deliveries/#{delivery["id"]}",
        Time.now.iso8601
      ]
    )
  end

  def notify(delivery, status, score)
    return unless defined?(SystemNotifier)

    SystemNotifier.new(@db).notify(
      kind: "validation_#{status}",
      title: status == "validated" ? "Entrega validada" : "Entrega precisa revisão",
      body: "Delivery ##{delivery["id"]} recebeu score #{score}.",
      link: "/deliveries/#{delivery["id"]}",
      dedupe_key: "validation_delivery_#{delivery["id"]}_#{status}"
    )
  end

  def register_failure(delivery_id, error)
    return unless delivery_id

    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        INSERT INTO validation_runs
        (
          delivery_id,
          status,
          score,
          summary,
          error,
          created_at,
          completed_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        delivery_id,
        "failed",
        0,
        "Erro ao validar entrega.",
        "#{error.class}: #{error.message}",
        now,
        now
      ]
    )
  rescue
  end

  def table_exists?(name)
    !!one("SELECT name FROM sqlite_master WHERE type='table' AND name = ?", [name])
  end

  def one(sql, params = [])
    row = @db.get_first_row(sql, params)
    row&.reject { |k, _| k.is_a?(Integer) }
  end

  def all(sql, params = [])
    @db.execute(sql, params).map { |row| row.reject { |k, _| k.is_a?(Integer) } }
  end
end
