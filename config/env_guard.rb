module EnvGuard
  REQUIRED_PRODUCTION_KEYS = [
    "DATABASE_URL",
    "PIX_WEBHOOK_SECRET",
    "RESPONSE_WEBHOOK_SECRET",
    "SESSION_SECRET",
    "ADMIN_PASSWORD",
    "ADMIN_USERNAME"
  ]

  PLACEHOLDER_VALUES = [
    "",
    "trocar_em_producao",
    "troque_este_segredo_em_producao",
    "cole_sua_chave_aqui",
    "teste_pix_123",
    "teste_response_123"
  ]

  def self.production?
    ENV["RACK_ENV"].to_s == "production" || ENV["APP_ENV"].to_s == "production"
  end

  def self.validate!
    return true unless production?

    missing = REQUIRED_PRODUCTION_KEYS.select do |key|
      PLACEHOLDER_VALUES.include?(ENV[key].to_s.strip)
    end

    if missing.any?
      raise "ENV inválido para produção. Configure: #{missing.join(', ')}"
    end

    true
  end
end

EnvGuard.validate!
