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
  CLONE_TIMEOUT_SECONDS = 30
  MAX_WORKSPACE_KB = 25_000

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
    stack = detect_stack_from_workspace(workspace, stack)
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

    update_repo_import(run_id, workspace, task, delivery)

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

  def detect_stack_from_workspace(workspace, fallback)
    search_root = File.exist?(File.join(workspace, "repo")) ? File.join(workspace, "repo") : workspace

    return "javascript" if File.exist?(File.join(search_root, "package.json"))
    return "ruby" if File.exist?(File.join(search_root, "Gemfile")) || File.exist?(File.join(search_root, "app.rb"))
    return "python" if File.exist?(File.join(search_root, "requirements.txt")) || Dir[File.join(search_root, "**", "*.py")].any?

    fallback
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

    repo_url = extract_repo_url(task, content)

    if repo_url
      import_repo(repo_url, workspace)
    end

    workspace
  end

  def extract_repo_url(task, content)
    text = [
      task && task["url"],
      task && task["source_url"],
      task && task["repository_url"],
      task && task["title"],
      content
    ].compact.join(" ")

    match = text.match(%r{https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+})
    return nil unless match

    match[0].sub(/\.git\z/, "")
  end

  def safe_github_url?(url)
    return false unless url
    return false unless url.start_with?("https://github.com/")
    return false if url.include?("..")
    return false if url.include?("@")
    return false if url.include?(";")
    return false if url.include?("|")
    return false if url.include?("&")

    true
  end

  def import_repo(repo_url, workspace)
    raise "Repo URL não permitida: #{repo_url}" unless safe_github_url?(repo_url)

    repo_dir = File.join(workspace, "repo")

    Timeout.timeout(CLONE_TIMEOUT_SECONDS) do
      _stdout, stderr, status = Open3.capture3(
        {},
        "git",
        "clone",
        "--depth",
        "1",
        repo_url,
        repo_dir,
        chdir: workspace
      )

      unless status.success?
        raise "git clone failed: #{stderr.to_s[0, 1000]}"
      end
    end

    size = workspace_size_kb(workspace)

    if size > MAX_WORKSPACE_KB
      FileUtils.rm_rf(repo_dir)
      raise "workspace too large: #{size}KB > #{MAX_WORKSPACE_KB}KB"
    end

    repo_dir
  rescue Timeout::Error
    raise "git clone timeout after #{CLONE_TIMEOUT_SECONDS}s"
  end

  def workspace_size_kb(path)
    total = 0

    Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).each do |file|
      next if File.directory?(file)
      total += File.size(file) rescue 0
    end

    (total / 1024.0).ceil
  end


  def choose_command(stack, workspace)
    search_root = File.exist?(File.join(workspace, "repo")) ? File.join(workspace, "repo") : workspace

    case stack
    when "ruby"
      app_rb = File.join(search_root, "app.rb")

      if File.exist?(app_rb)
        return {
          label: "ruby_syntax_app",
          command: ["ruby", "-c", app_rb],
          chdir: search_root
        }
      end

      rb = Dir[File.join(search_root, "**", "*.rb")].first
      if rb
        return {
          label: "ruby_syntax_file",
          command: ["ruby", "-c", rb],
          chdir: search_root
        }
      end

    when "javascript"
      pkg = File.join(search_root, "package.json")

      if File.exist?(pkg)
        return {
          label: "npm_build",
          command: ["npm", "run", "build"],
          chdir: search_root
        }
      end

    when "python"
      py = Dir[File.join(search_root, "**", "*.py")].first

      if py
        return {
          label: "python_compile",
          command: ["python3", "-m", "py_compile", py],
          chdir: search_root
        }
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
        chdir: command_spec[:chdir] || workspace
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

  def update_repo_import(run_id, workspace, task, delivery)
    content = [
      delivery["title"],
      delivery["content"],
      delivery["body"],
      delivery["result"],
      delivery["notes"]
    ].compact.join("\n\n")

    repo_url = extract_repo_url(task, content)
    size = workspace_size_kb(workspace)

    import_status =
      if repo_url && File.exist?(File.join(workspace, "repo"))
        "imported"
      elsif repo_url
        "not_imported"
      else
        "no_repo"
      end

    @db.execute(
      <<~SQL,
        UPDATE validation_sandbox_runs
        SET repo_url = ?,
            repo_import_status = ?,
            workspace_size_kb = ?
        WHERE id = ?
      SQL
      [repo_url, import_status, size, run_id]
    )
  rescue => e
    @db.execute(
      "UPDATE validation_sandbox_runs SET repo_import_status = ?, repo_import_error = ? WHERE id = ?",
      ["failed", "#{e.class}: #{e.message}", run_id]
    )
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
