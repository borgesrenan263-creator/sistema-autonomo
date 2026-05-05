class TaskRepository
  def initialize(db)
    @db = db
  end

  def find(id)
    clean(@db.get_first_row("SELECT * FROM tasks WHERE id = ?", [id]))
  end

  def latest(limit: 250)
    @db.execute(
      <<~SQL,
        SELECT *
        FROM tasks
        WHERE quality_status != 'ignore'
        ORDER BY
          CASE quality_status
            WHEN 'monetizable' THEN 3
            WHEN 'review' THEN 2
            ELSE 1
          END DESC,
          demand_score DESC,
          suggested_price DESC,
          id DESC
        LIMIT ?
      SQL
      [limit]
    ).map { |row| clean(row) }
  end

  def mark_ok(id, paid_at:)
    @db.execute(
      <<~SQL,
        UPDATE tasks
        SET status = 'ok',
            stage = 'historico',
            paid_at = ?,
            updated_at = ?
        WHERE id = ?
      SQL
      [paid_at, paid_at, id]
    )
  end

  private

  def clean(row)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
