module AppSettings
  DEFAULTS = {
    "APP_ENV" => "development",
    "APP_HOST" => "0.0.0.0",
    "APP_PORT" => "4567",

    "GEMINI_MODEL" => "gemini-2.5-flash",
    "AI_MIN_DELIVERY_CHARS" => "1200",
    "AI_MIN_PROPOSAL_CHARS" => "1000",

    "RESCAN_INTERVAL_SECONDS" => "300",

    "PIX_PROVIDER" => "manual",
    "EMAIL_PROVIDER" => "manual",
    "WHATSAPP_PROVIDER" => "manual"
  }

  SECRET_PATTERNS = [
    /KEY/i,
    /TOKEN/i,
    /SECRET/i,
    /PASSWORD/i
  ]

  def self.load!
    load_env_file(File.expand_path("../.env", __dir__))
    DEFAULTS.each do |key, value|
      ENV[key] = value if ENV[key].nil? || ENV[key].strip.empty?
    end
  end

  def self.load_env_file(path)
    return unless File.exist?(path)

    File.readlines(path).each do |line|
      clean = line.strip
      next if clean.empty?
      next if clean.start_with?("#")
      next unless clean.include?("=")

      key, value = clean.split("=", 2)
      key = key.to_s.strip
      value = value.to_s.strip

      value = value[1..-2] if value.start_with?('"') && value.end_with?('"')
      value = value[1..-2] if value.start_with?("'") && value.end_with?("'")

      ENV[key] = value unless key.empty?
    end
  end

  def self.get(key)
    ENV[key] || DEFAULTS[key]
  end

  def self.enabled?(key)
    value = get(key).to_s.strip
    !value.empty? &&
      value != "cole_sua_chave_aqui" &&
      value != "trocar_em_producao"
  end

  def self.secret?(key)
    SECRET_PATTERNS.any? { |pattern| key.to_s.match?(pattern) }
  end

  def self.mask(key, value)
    value = value.to_s

    return "" if value.empty?
    return value unless secret?(key)

    return "configurado" if value.length < 8

    "#{value[0, 4]}...#{value[-4, 4]}"
  end

  def self.rows
    keys = (
      DEFAULTS.keys +
      [
        "GEMINI_API_KEY",
        "PIX_WEBHOOK_SECRET",
        "SMTP_HOST",
        "SMTP_PORT",
        "SMTP_USER",
        "SMTP_PASSWORD",
        "WHATSAPP_TOKEN",
        "WHATSAPP_PHONE_NUMBER_ID"
      ]
    ).uniq

    keys.map do |key|
      value = get(key).to_s

      {
        key: key,
        value: mask(key, value),
        configured: enabled?(key),
        secret: secret?(key)
      }
    end
  end

  def self.provider_summary
    {
      app_env: get("APP_ENV"),
      gemini_model: get("GEMINI_MODEL"),
      gemini_ready: enabled?("GEMINI_API_KEY"),
      pix_provider: get("PIX_PROVIDER"),
      email_provider: get("EMAIL_PROVIDER"),
      whatsapp_provider: get("WHATSAPP_PROVIDER"),
      worker_interval: get("RESCAN_INTERVAL_SECONDS")
    }
  end
end

AppSettings.load!
