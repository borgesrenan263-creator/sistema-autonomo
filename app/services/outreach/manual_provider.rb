require "time"

class ManualProvider
  def initialize(db)
    @db = db
  end

  def send_message(message)
    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        UPDATE outreach_messages
        SET status = 'sent',
            sent_at = ?,
            updated_at = ?
        WHERE id = ?
      SQL
      [now, now, message["id"]]
    )

    {
      ok: true,
      provider: "manual_provider",
      sent_at: now,
      note: "Mensagem marcada como enviada pelo provider manual."
    }
  end
end
