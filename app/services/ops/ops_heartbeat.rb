require "time"
require "json"

class OpsHeartbeat
  def initialize(db)
    @db = db
  end

  def beat(component:, status: "ok", detail: nil, metadata: {})
    now = Time.now.iso8601
    payload = JSON.generate(metadata || {})

    existing = one(
      "SELECT * FROM ops_heartbeats WHERE component = ? LIMIT 1",
      [component]
    )

    if existing
      @db.execute(
        <<~SQL,
          UPDATE ops_heartbeats
          SET status = ?,
              detail = ?,
              metadata = ?,
              last_seen_at = ?,
              updated_at = ?
          WHERE component = ?
        SQL
        [status, detail, payload, now, now, component]
      )
    else
      @db.execute(
        <<~SQL,
          INSERT INTO ops_heartbeats
          (
            component,
            status,
            detail,
            metadata,
            last_seen_at,
            created_at,
            updated_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?)
        SQL
        [component, status, detail, payload, now, now, now]
      )
    end
  end

  def all
    @db.execute("SELECT * FROM ops_heartbeats ORDER BY component ASC").map do |row|
      row.reject { |k, _| k.is_a?(Integer) }
    end
  end

  private

  def one(sql, params = [])
    row = @db.get_first_row(sql, params)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
