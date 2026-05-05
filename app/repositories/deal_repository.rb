class DealRepository
  OPEN_STATUSES = ["proposta_criada", "abordado", "interessado"]

  def initialize(db)
    @db = db
  end

  def find(id)
    clean(@db.get_first_row("SELECT * FROM deals WHERE id = ?", [id]))
  end

  def open_for_task(task_id)
    clean(
      @db.get_first_row(
        <<~SQL,
          SELECT deals.*, proposals.id AS proposal_id
          FROM deals
          LEFT JOIN proposals ON proposals.id = deals.proposal_id
          WHERE deals.task_id = ?
            AND deals.status IN ('proposta_criada', 'abordado', 'interessado')
          ORDER BY deals.id DESC
          LIMIT 1
        SQL
        [task_id]
      )
    )
  end

  private

  def clean(row)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
