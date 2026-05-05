require "time"

class SystemNotifier
  def initialize(db)
    @db = db
  end

  def notify(kind:, title:, body:, link: nil, metadata: nil, dedupe_key: nil)
    if dedupe_key
      existing = one(
        <<~SQL,
          SELECT *
          FROM system_notifications
          WHERE kind = ?
            AND metadata = ?
            AND status = 'unread'
          ORDER BY id DESC
          LIMIT 1
        SQL
        [kind, dedupe_key]
      )

      return existing if existing
    end

    now = Time.now.iso8601

    @db.execute(
      <<~SQL,
        INSERT INTO system_notifications
        (
          kind,
          title,
          body,
          status,
          link,
          metadata,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        kind,
        title,
        body,
        "unread",
        link,
        dedupe_key || metadata,
        now
      ]
    )

    one("SELECT * FROM system_notifications WHERE id = ?", [@db.last_insert_row_id])
  end

  def unread(limit: 5)
    @db.execute(
      <<~SQL,
        SELECT *
        FROM system_notifications
        WHERE status = 'unread'
        ORDER BY id DESC
        LIMIT ?
      SQL
      [limit]
    ).map { |row| clean(row) }
  end

  private

  def one(sql, params = [])
    row = @db.get_first_row(sql, params)
    clean(row)
  end

  def clean(row)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
