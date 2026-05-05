class LocalDeliveryBuilder
  def self.build(task)
    title = task["title"].to_s
    source = task["source"].to_s
    url = task["url"].to_s
    score = task["demand_score"].to_i
    price = task["suggested_price"].to_i
    quality = task["quality_status"].to_s
    reason = task["quality_reason"].to_s

    category = detect_category(title)
    diagnosis = diagnosis_for(category)
    plan = plan_for(category)

    content = <<~TEXT
      SISTEMA AUTÔNOMO — ENTREGA REAL

      Fonte:
      #{source}

      Link de origem:
      #{url}

      Oportunidade detectada:
      #{title}

      Categoria:
      #{category}

      Score:
      #{score}/10

      Qualidade:
      #{quality} — #{reason}

      Preço sugerido:
      R$ #{price}

      DIAGNÓSTICO
      #{diagnosis}

      PLANO DE CORREÇÃO / ENTREGA
      #{plan}

      CHECKLIST DE ENTREGA
      [ ] Ler a origem completa
      [ ] Confirmar contexto técnico
      [ ] Reproduzir ou validar o problema
      [ ] Escrever correção, diagnóstico ou proposta
      [ ] Preparar resposta objetiva
      [ ] Registrar resultado no sistema
      [ ] Marcar OK somente se a entrega foi validada

      MENSAGEM DE ABORDAGEM
      Olá, vi este problema aberto: "#{title}".
      Montei um diagnóstico objetivo com um caminho de correção e próximos passos.
      Se fizer sentido, posso te enviar uma versão curta da solução e um checklist técnico.

      OBSERVAÇÃO OPERACIONAL
      Esta entrega foi gerada a partir de uma oportunidade pública real.
      Revisão humana recomendada antes de contato externo ou cobrança.
    TEXT

    {
      category: category,
      content: content
    }
  end

  def self.detect_category(title)
    t = title.downcase

    return "Build / DevOps" if t.include?("storybook") || t.include?("build") || t.include?("ci") || t.include?("deploy") || t.include?("runtime") || t.include?("dev")
    return "Bug técnico" if t.include?("bug") || t.include?("broken") || t.include?("not working") || t.include?("error") || t.include?("crash") || t.include?("failed") || t.include?("fails")
    return "UX / Interface" if t.include?("button") || t.include?("dropdown") || t.include?("ui") || t.include?("ux")
    return "Automação / Workflow" if t.include?("automation") || t.include?("workflow")
    return "Produto / Feature" if t.include?("feature") || t.include?("api") || t.include?("integration")

    "Microserviço técnico"
  end

  def self.diagnosis_for(category)
    case category
    when "Bug técnico"
      "O item indica falha objetiva em uso real. A entrega ideal é análise curta da causa provável, reprodução do erro e sugestão de correção mínima."
    when "UX / Interface"
      "O item indica atrito de interface. A entrega ideal é diagnóstico de UX, sugestão de componente ou ajuste de fluxo."
    when "Build / DevOps"
      "O item indica problema de build, ambiente, dependência ou ferramenta de desenvolvimento. A entrega ideal é checklist de reprodução, hipótese de causa e correção incremental."
    when "Automação / Workflow"
      "O item indica processo repetitivo ou fluxo manual. A entrega ideal é script, automação simples ou desenho de pipeline."
    when "Produto / Feature"
      "O item indica necessidade de produto, API ou integração. A entrega ideal é especificação curta, plano técnico e proposta de implementação."
    else
      "O item apresenta sinal de dor técnica ou operacional. A entrega deve ser objetiva, pequena e validável."
    end
  end

  def self.plan_for(category)
    case category
    when "Bug técnico"
      "1. Identificar comportamento esperado.\n2. Identificar comportamento atual.\n3. Listar hipótese principal da causa.\n4. Sugerir correção mínima.\n5. Criar resposta técnica curta com próximos passos."
    when "UX / Interface"
      "1. Descrever o atrito do usuário.\n2. Sugerir melhoria de layout ou componente.\n3. Definir comportamento esperado.\n4. Criar texto de implementação.\n5. Entregar checklist de validação."
    when "Build / DevOps"
      "1. Levantar ambiente e dependências.\n2. Identificar ponto de falha.\n3. Sugerir comando de reprodução.\n4. Propor correção incremental.\n5. Entregar checklist de build."
    when "Automação / Workflow"
      "1. Mapear entrada, processo e saída.\n2. Identificar etapa repetitiva.\n3. Propor script ou automação.\n4. Definir formato de entrega.\n5. Criar instrução de uso."
    else
      "1. Ler a origem.\n2. Resumir a dor.\n3. Criar hipótese de solução.\n4. Montar entrega curta.\n5. Validar manualmente antes de usar."
    end
  end
end
