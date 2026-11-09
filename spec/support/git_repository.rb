require 'fileutils'
require 'open3'
require 'tmpdir'

# A throwaway git repository for specs that read real git history.
class GitRepository
  ENV_VARS = {
    "GIT_CONFIG_GLOBAL" => File::NULL,
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_AUTHOR_NAME" => "Spec",
    "GIT_AUTHOR_EMAIL" => "spec@example.com",
    "GIT_COMMITTER_NAME" => "Spec",
    "GIT_COMMITTER_EMAIL" => "spec@example.com"
  }

  attr_reader :path

  def self.create
    Dir.mktmpdir("qawolf-changes") do |dir|
      repository = new(File.join(dir, "app"))
      repository.git("init", "--quiet", "--initial-branch=main", repository.path)
      yield(repository, dir)
    end
  end

  def initialize(path)
    @path = path
  end

  def git(*args, cwd: nil)
    stdout, stderr, status = Open3.capture3(ENV_VARS, "git", *args, chdir: cwd || File.dirname(path))
    raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?

    stdout.strip
  end

  def commit(message, files = {})
    files.each do |name, content|
      FileUtils.mkdir_p(File.dirname(File.join(path, name)))
      File.write(File.join(path, name), content)
    end
    git("add", "--all", cwd: path)
    git("commit", "--quiet", "--allow-empty", "--message", message, cwd: path)
    git("rev-parse", "HEAD", cwd: path)
  end
end
