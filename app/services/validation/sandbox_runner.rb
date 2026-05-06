require "fileutils"
require "open3"
require "timeout"
require "time"
require "securerandom"

class SandboxRunner
  ROOT = File.expand_path("../../..", __dir__)
  SANDBOX_ROOT = File.join(ROOT, "storage", "tmp", "sandbox")
  EVIDENCE_ROOT = File.join(ROOT, "storage", "exports", "validation_sandbox")

  TIMEOUT_SECONDS = 20

  ALLOWLIST = {
    "ruby_syntax_app" => {
      stack: "ruby",
      command: ["ruby", "-c", "app.rb"],
      required_files: ["app.rb"]
    },
    "ruby_syntax_all" => {
      stack: "ruby",
      command: ["ruby", "-c"],
      dynamic_file: true,
      file_glob: "**/*.rb"
    },
    "npm_build" => {
      stack: "javascript",
      command: ["npm", "run", "build"],
      required_files: ["package.json"]
    },
    "npm_test" => {
      stack: "javascript",
      command: ["npm", "test", "--", "--runInBand"],
      required_files: ["package.json"]
    },
    "python_compile" => {
      stack: "python",
      command: ["python3", "-m", "py_compile"],
      dynamic_file: true,
      file_glob: "**/*.py"
    }
  }

  def initialize(db)
    @db = db
    FileUtils.mkdir_p(SANDBOX_ROOT)
    FileUtils.mkdir_p(EVIDENCE_ROOT)
  end

  def run_for_delivery(delivery_id)
    delivery = one("SELECT * FROM deliveries WHERE id = ?", [delivery_id])
    raise "Delivery não encontrada" unless delivery

    task = one("SELECT * FROM tasks WHERE id = ?", [delivery["task_id"]])
    latest_validation = one(
      "SELECT * FROM validation_runs WHERE delivery_id = ? ORDER BY id DESC LIMIT 1",
      [delivery_id]
    )

    stack = detect_stack(delivery, task, latest_validation)
    workspace = prepare_workspace(delivery, task)
    command_spec = choose_command(stack, workspace)

    started = Time.now.iso8601

    run_id = create_run(
      delivery: delivery,
      validation_run: latest_validation,
      stack: stack,
      workspace: workspace,
      command: command_spec ? command_spec[:label] : "none",
      started: started
    )

    unless command_spec
      finish_run(
        run_id: run_id,
        status: "manual_review",
        exit_status: nil,
        stdout: "",
        stderr: "",
        error: "Nenhum comando permitido encontrado para stack=#{stack}",
        workspace: workspace
      )
      update_validation(latest_validation, "manual_review", nil)
      return one("SELECT * FROM validation_sandbox_runs WHERE id = ?", [run_id])
    end

    result = execute_command(command_spec, workspace)

    status =
      if result[:exit_status] == 0
        "passed"
      else
        "failed"
      end

    evidence_path = write_evidence(
      run_id: run_id,
      delivery: delivery,
      task: task,
      stack: stack,
      workspace: workspace,
      command: command_spec,
      result: result,
      status: status
    )

    finish_run(
      run_id: run_id,
      status: status,
      exit_status: result[:exit_status],
      stdout: result[:stdout],
      stderr: result[:stderr],
      error: result[:error],
      evidence_path: evidence_path,
      workspace: workspace
    )

    update_validation(latest_validation, status, evidence_path)
    notify(delivery, status)

    one("SELECT * FROM validation_sandbox_runs WHERE id = ?", [run_id])
  rescue => e
    register_failure(delivery_id, e)
    raise e
  end

  def run_latest(limit = 5)
    deliveries = all(
      <<~SQL,
        SELECT *
        FROM deliveries
        WHERE validation_status = 'validated'
           OR validation_status = 'manual_review'
        ORDER BY id DESC
        LIMIT ?
      SQL
      [limit]
    )

    deliveries.map do |delivery|
      begin
        run_for_delivery(delivery["id"])
      rescue => e
        { "delivery_id" => delivery["id"], "error" => e.message }
      end
    end
  end

  private

  def detect_stack(delivery, task, validation_run)
    explicit = validation_run && validation_run["stack_detected"].to_s
    return explicit.split(",").first if explicit && !explicit.empty? && explicit != "unknown"

    text = [
      delivery["title"],
      delivery["content"],
      delivery["body"],
      delivery["result"],
      delivery["notes"],
      task && task["title"],
      task && task["source"],
      task && task["url"]
    ].compact.join(" ").downcase

    return "ruby" if text.include?("ruby") || text.include?("sinatra") || text.include?("rails")
    return "javascript" if text.include?("node") || text.include?("npm") || text.include?("react") || text.include?("vite")
    return "python" if text.include?("python") || text.include?("flask") || text.include?("django")

    "unknown"
  end

  def prepare_workspace(delivery, task)
    id = "delivery-#{delivery["id"]}-#{SecureRandom.hex(4)}"
    workspace = File.join(SANDBOX_ROOT, id)
    FileUtils.rm_rf(workspace)
    FileUtils.mkdir_p(workspace)

    content = [
      delivery["title"],
      delivery["content"],
      delivery["body"],
      delivery["result"],
      delivery["notes"]
    ].compact.join("\n\n")

    File.write(File.join(workspace, "README_DELIVERY.txt"), content)

    # Sandbox v1 não clona repo externo. Apenas cria workspace isolado e roda checks se arquivos existirem.
    workspace
  end

  def choose_command(stack, workspace)
    case stack
    when "ruby"
      if File.exist?(File.join(workspace, "app.rb"))
        return { label: "ruby_syntax_app", command: ALLOWLIST["ruby_syntax_app"][:command] }
      end
    when "javascript"
      if File.exist?(File.join(workspace, "package.json"))
        return { label: "npm_build", command: ALLOWLIST["npm_build"][:command] }
      end
    when "python"
      py = Dir[File.join(workspace, "**", "*.py")].first
      if py
        return { label: "python_compile", command: ALLOWLIST["python_compile"][:command] + [py] }
      end
    end

    nil
  end

  def execute_command(command_spec, workspace)
    stdout = ""
    stderr = ""
    status_code = nil
    error = nil

    Timeout.timeout(TIMEOUT_SECONDS) do
      stdout, stderr, status = Open3.capture3(
        {},
        *command_spec[:command],
        chdir: workspace
      )
      status_code = status.exitstatus
    end

    {
      stdout: stdout.to_s[0, 6000],
      stderr: stderr.to_s[0, 6000],
      exit_status: status_code,
      error: error
    }
  rescue Timeout::Error
    {
      stdout: stdout.to_s[0, 6000],
      stderr: stderr.to_s[0, 6000],
      exit_status: 124,
      error: "timeout_after_#{TIMEOUT_SECONDS}s"
    }
  rescue => e
    {
      stdout: stdout.to_s[0, 6000],
      stderr: stderr.to_s[0, 6000],
      exit_status: 1,
      error: "#{e.class}: #{e.message}"
    }
  end

  def create_run(delivery:, validation_run:, stack:, workspace:, command:, started:)
    @db.execute(
      <<~SQL,
        INSERT INTO validation_sandbox_runs
        (
          delivery_id,
          task_id,
          validation_run_id,
          status,
          stack_detected,
          command,
          workspace_path,
          started_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        delivery["id"],
        delivery["task_id"],
        validation_run && validation_run["id"],
        "running",
        stack,
        command,
        workspace,
        started
      ]
    )

    @db.last_insert_row_id
  end

  def finish_run(run_id:, status:, exit_status:, stdout:, stderr:, error:, workspace:, evidence_path: nil)
    @db.execute(
      <<~SQL,
        UPDATE validation_sandbox_runs
        SET status = ?,
            exit_status = ?,
            stdout = ?,
            stderr = ?,
            error = ?,
            evidence_path = ?,
            workspace_path = ?,
            finished_at = ?
        WHERE id = ?
      SQL
      [
        status,
        exit_status,
        stdout,
        stderr,
        error,
        evidence_path,
        workspace,
        Time.now.iso8601,
        run_id
      ]
    )
  end

  def write_evidence(run_id:, delivery:, task:, stack:, workspace:, command:, result:, status:)
    path = File.join(EVIDENCE_ROOT, "sandbox-run-#{run_id}.txt")

    File.write(path, <<~TXT)
      SISTEMA AUTONOMO — SANDBOX VALIDATION
      =====================================

      Run ID: #{run_id}
      Delivery ID: #{delivery["id"]}
      Task ID: #{delivery["task_id"]}
      Status: #{status}
      Stack: #{stack}
      Command: #{command[:label]}
      Exit status: #{result[:exit_status]}
      Workspace: #{workspace}
      Generated at: #{Time.now.iso8601}

      ERROR
      -----
      #{result[:error] || "-"}

      STDOUT
      ------
      #{result[:stdout]}

      STDERR
      ------
      #{result[:stderr]}
    TXT

    path
  end

  def update_validation(validation_run, status, evidence_path)
    return unless validation_run

    @db.execute(
      <<~SQL,
        UPDATE validation_runs
        SET sandbox_status = ?,
            sandbox_evidence_path = ?
        WHERE id = ?
      SQL
      [status, evidence_path, validation_run["id"]]
    )
  end

  def notify(delivery, status)
    return unless defined?(SystemNotifier)

    SystemNotifier.new(@db).notify(
      kind: "sandbox_#{status}",
      title: status == "passed" ? "Sandbox passou" : "Sandbox precisa atenção",
      body: "Delivery ##{delivery["id"]} sandbox status: #{status}.",
      link: "/validation/sandbox",
      dedupe_key: "sandbox_delivery_#{delivery["id"]}_#{status}"
    )
  end

  def register_failure(delivery_id, error)
    @db.execute(
      <<~SQL,
        INSERT INTO validation_sandbox_runs
        (
          delivery_id,
          status,
          error,
          started_at,
          finished_at
        )
        VALUES (?, ?, ?, ?, ?)
      SQL
      [
        delivery_id,
        "failed",
        "#{error.class}: #{error.message}",
        Time.now.iso8601,
        Time.now.iso8601
      ]
    )
  rescue
  end

  def one(sql, params = [])
    row = @db.get_first_row(sql, params)
    row&.reject { |k, _| k.is_a?(Integer) }
  end

  def all(sql, params = [])
    @db.execute(sql, params).map { |row| row.reject { |k, _| k.is_a?(Integer) } }
  end
end
