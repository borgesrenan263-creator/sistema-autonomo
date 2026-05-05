class OutreachBuilder
  def self.build(task:, deal:, contact:, proposal: nil)
    title = task["title"].to_s
    source = task["source"].to_s
    url = task["url"].to_s
    value = deal["value"].to_i

    subject = "Diagnóstico objetivo sobre: #{title}"

    body = <<~TXT.strip
      Olá, tudo bem?

      Vi esta oportunidade pública em #{source}:

      "#{title}"

      Montei uma análise objetiva com:
      - diagnóstico inicial
      - hipótese de causa
      - caminho de correção
      - checklist de validação
      - próximos passos

      Origem:
      #{url}

      A proposta é uma microentrega curta e revisável, sem promessa de correção garantida e sem acesso a ambientes privados.

      Valor sugerido:
      R$ #{value}

      Se fizer sentido, posso te enviar a versão curta da análise para avaliação.
    TXT

    {
      subject: subject,
      message_body: body
    }
  end
end
