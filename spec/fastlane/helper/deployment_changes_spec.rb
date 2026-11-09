require_relative '../../support/git_repository'

describe Fastlane::Helper::DeploymentChanges do
  let(:all_levels) { %w[titles descriptions paths] }

  def commit(subject, body: "", paths: [])
    { body: body, paths: paths, subject: subject }
  end

  def summarize(commits, total_count: commits.length, include: all_levels)
    described_class.summarize(commits: commits, total_count: total_count, include: include)
  end

  # Builds a repository with the given block, which returns the `since` to
  # collect from and, optionally, the directory to collect in.
  def collect(include: all_levels)
    GitRepository.create do |repository, dir|
      since, cwd = yield(repository, dir)
      return described_class.collect_commits(since: since, include: include, cwd: cwd || repository.path)
    end
  end

  def changes_after(&setup)
    result = collect(&setup)
    summarize(result[:commits], total_count: result[:total_count])
  end

  def two_commits(repository)
    base = repository.commit("Initial commit", "README.md" => "hello")
    repository.commit("Add the cart\n\nShows the items in the cart.", "app/Cart.swift" => "struct Cart {}")
    repository.commit("Fix the total", "app/Total.swift" => "let total = 1")
    base
  end

  def rotated_secret(repository)
    base = repository.commit("Initial commit", "config.txt" => "token=first-secret-value")
    repository.commit("Rotate the token", "config.txt" => "token=second-secret-value")
    base
  end

  def merged_pull_request(repository)
    base = repository.commit("Initial commit", "README.md" => "hello")
    repository.git("checkout", "--quiet", "-b", "feature/cart", cwd: repository.path)
    repository.commit("Add the cart", "app/Cart.swift" => "struct Cart {}")
    repository.git("checkout", "--quiet", "main", cwd: repository.path)
    repository.git("merge", "--quiet", "--no-ff", "-m", "Merge pull request #12 from my-org/feature/cart\n\nAdd the cart\n\nLets shoppers review their cart.", "feature/cart", cwd: repository.path)
    base
  end

  def shallow_clone(repository, dir)
    base = two_commits(repository)
    shallow = File.join(dir, "shallow")
    repository.git("clone", "--quiet", "--depth", "1", "file://#{repository.path}", shallow)
    [base, shallow]
  end

  describe ".collect_commits" do
    let(:two_commits_changes) do
      {
        "items" => [
          { "changedPaths" => ["app/Total.swift"], "kind" => "commit", "title" => "Fix the total" },
          { "changedPaths" => ["app/Cart.swift"], "description" => "Shows the items in the cart.", "kind" => "commit", "title" => "Add the cart" }
        ]
      }
    end
    let(:merged_pull_request_changes) do
      {
        "items" => [
          { "changedPaths" => ["app/Cart.swift"], "description" => "Lets shoppers review their cart.", "kind" => "pull-request", "title" => "Add the cart" }
        ]
      }
    end

    it "reads each commit after since up to HEAD, newest first, with its message and paths" do
      expect(changes_after { |repository| two_commits(repository) }).to eq(two_commits_changes)
    end

    it "never reads file contents or diffs" do
      expect(changes_after { |repository| rotated_secret(repository) }.to_json).not_to match(/secret-value|token=/)
    end

    it "lists the paths a merged pull request changed on its merge commit" do
      expect(changes_after { |repository| merged_pull_request(repository) }).to eq(merged_pull_request_changes)
    end

    it "refuses a shallow clone" do
      result = collect { |repository, dir| shallow_clone(repository, dir) }
      expect(result).to include(ok: false, message: a_string_including("shallow"))
    end

    it "explains a since that names no commit" do
      result = collect { |repository| two_commits(repository) && "v9.9.9" }
      expect(result).to include(ok: false, message: a_string_including("\"v9.9.9\" names no commit"))
    end

    it "does not read since as a git option" do
      Dir.mktmpdir do |outside|
        collect { |repository| two_commits(repository) && "--output=#{File.join(outside, 'leaked')}" }
        expect(File.exist?(File.join(outside, "leaked"))).to be(false)
      end
    end
  end

  describe ".summarize" do
    let(:many_paths) { Array.new(1000) { |index| "app/#{'nested/' * 20}File#{index}.swift" } }
    let(:oversized) { summarize(Array.new(40) { |index| commit("Commit #{index}", paths: many_paths) }) }
    let(:capped) { summarize(Array.new(250) { |index| commit("Commit #{index}") }, total_count: 300) }

    it "reads a squash-merged commit as a pull request" do
      expect(summarize([commit("Add the cart (#12)")])).to eq("items" => [{ "kind" => "pull-request", "title" => "Add the cart (#12)" }])
    end

    it "reads a GitLab merge commit holding only the trailer by its subject" do
      changes = summarize([commit("Merge branch 'cart' into 'main'", body: "See merge request my-group/my-app!7")])
      expect(changes).to eq("items" => [{ "kind" => "pull-request", "title" => "Merge branch 'cart' into 'main'" }])
    end

    it "sends titles alone unless descriptions and paths are asked for" do
      changes = summarize([commit("Add the cart", body: "Details", paths: ["app/Cart.swift"])], include: %w[titles])
      expect(changes).to eq("items" => [{ "kind" => "commit", "title" => "Add the cart" }])
    end

    it "keeps the newest 250 commits" do
      expect(capped["items"].length).to eq(250)
    end

    it "counts the commits it did not read" do
      expect(capped["omittedCount"]).to eq(50)
    end

    it "stays within 256 KB" do
      expect(JSON.generate(oversized).bytesize).to be <= 256 * 1024
    end

    it "counts every change it left out to fit" do
      expect(oversized["items"].length + oversized["omittedCount"]).to eq(40)
    end

    it "cuts a long title to the API's limit, counting as JavaScript does" do
      expect(summarize([commit("🐺" * 300)])["items"].first["title"]).to eq("🐺" * 256)
    end
  end

  describe ".validate" do
    def refusal_of(changes)
      described_class.validate(changes)
    rescue FastlaneCore::Interface::FastlaneError => e
      e.message
    end

    it "accepts symbol keys and trims text" do
      changes = described_class.validate(items: [{ kind: "commit", title: " Add the cart ", changedPaths: ["app/Cart.swift"] }], releaseNotes: "Cart")
      expect(changes).to eq("items" => [{ "changedPaths" => ["app/Cart.swift"], "kind" => "commit", "title" => "Add the cart" }], "releaseNotes" => "Cart")
    end

    it "refuses a key for code or diffs" do
      expect(refusal_of(items: [{ kind: "commit", title: "Add the cart", diff: "+ let total = 1" }])).to match(/unknown keys: diff/)
    end

    it "refuses an unknown top-level key" do
      expect(refusal_of(files: { "app/Cart.swift" => "struct Cart {}" })).to match(/unknown keys: files/)
    end

    it "refuses an unknown kind" do
      expect(refusal_of(items: [{ kind: "merge", title: "Add the cart" }])).to match(/kind` must be one of/)
    end

    it "refuses a title over the limit" do
      expect(refusal_of(items: [{ kind: "commit", title: "a" * 513 }])).to match(/title` must be at most 512/)
    end

    it "refuses a blank title" do
      expect(refusal_of(items: [{ kind: "commit", title: "  " }])).to match(/title` must be a non-empty string/)
    end

    it "refuses more than 250 items" do
      expect(refusal_of(items: Array.new(251) { { kind: "commit", title: "Commit" } })).to match(/at most 250/)
    end

    it "refuses a url that is not http" do
      expect(refusal_of(items: [{ kind: "commit", title: "Add the cart", url: "ftp://example.com" }])).to match(/url` must be an http/)
    end

    it "treats a summary with no items and no release notes as not sent" do
      expect(described_class.validate(items: [], omittedCount: 3)).to be_nil
    end
  end
end
