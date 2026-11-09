require 'fastlane_core'
require 'fastlane_core/ui/ui'
require 'json'
require 'open3'

module Fastlane
  UI = FastlaneCore::UI unless Fastlane.const_defined?(:UI)

  module Helper
    # The `changes` summary `deployment.reportStatus` accepts: each pull request
    # or commit a deployment ships, with its title, and optionally its
    # description and changed file paths, plus release notes. It has no field
    # for code, so diffs and file contents can never be sent.
    module DeploymentChanges
      MAX_ITEMS = 250
      MAX_TITLE_LENGTH = 512
      MAX_DESCRIPTION_LENGTH = 4000
      MAX_PATHS_PER_ITEM = 1000
      MAX_PATH_LENGTH = 1024
      MAX_URL_LENGTH = 2048
      MAX_RELEASE_NOTES_LENGTH = 16_000
      MAX_BYTES = 256 * 1024
      # One change's share, so a change with many paths leaves room for the rest.
      MAX_BYTES_PER_ITEM = MAX_BYTES / 8

      KINDS = %w[pull-request commit]
      INCLUDE_LEVELS = %w[titles descriptions paths]
      CHANGES_KEYS = %w[items omittedCount releaseNotes]
      ITEM_KEYS = %w[changedPaths description kind title url]

      # The hash, subject and body of each commit, each ending in a NUL, which
      # commit text and paths can't hold.
      LOG_FORMAT = "%H%x00%s%x00%b%x00"
      HASH_PATTERN = /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
      # A record holds its hash, subject, body and git's separator, then its paths.
      FIELDS_BEFORE_PATHS = 4

      # A merge commit's subject names the branch; its body starts with the
      # pull or merge request title.
      MERGE_SUBJECT_PATTERN = /\AMerge (pull request #\d+|branch .+ into )/
      SQUASH_SUBJECT_PATTERN = /\(#\d+\)\z/
      MERGE_REQUEST_TRAILER_PATTERN = /^See merge request \S+$/

      HISTORY_FIX = "Fetch the full history before collecting changes, e.g. `fetch-depth: 0` on actions/checkout, or `git fetch --unshallow`."

      def self.config_items
        [
          FastlaneCore::ConfigItem.new(key: :changes,
                                       description: "What the deployment changed, as `{ items: [{ kind:, title:, description:, changedPaths:, url: }], omittedCount:, releaseNotes: }`. There is no field for code, diffs or file contents. Cannot be combined with `collect_changes` or `pull_request_title`",
                                       optional: true,
                                       type: Hash),
          FastlaneCore::ConfigItem.new(key: :collect_changes,
                                       description: "Collect the changes from the local git history: each commit after `changes_since` up to HEAD, with its message and changed file paths, never diffs or file contents. Off by default. A shallow clone sends no commits and warns",
                                       optional: true,
                                       default_value: false,
                                       type: Boolean),
          FastlaneCore::ConfigItem.new(key: :changes_since,
                                       description: "The commit, tag or branch the environment ran before, e.g. `origin/main` for a pull request build or `v1.2.0` for a release. Required with `collect_changes`",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :changes_include,
                                       description: "What `collect_changes` sends for each commit: `titles`, `descriptions` (the message body) and `paths` (the changed file paths). Defaults to all three",
                                       optional: true,
                                       type: Array),
          FastlaneCore::ConfigItem.new(key: :pull_request_title,
                                       description: "The pull request's title, sent as the first change. Git alone doesn't know it",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :pull_request_description,
                                       description: "The pull request's description, sent with `pull_request_title`",
                                       optional: true,
                                       type: String)
        ]
      end

      # What the deployment changed: `changes` as given, or the pull request
      # followed by the commits collected from git. Nil when none of these is
      # set, so the report carries no `changes`. Collecting never fails the
      # lane: when git can't answer, it warns and sends no commits.
      def self.from_options(params, cwd:)
        pull_request = pull_request_item(params)
        unless params[:changes].nil?
          reject_combined(params, pull_request)
          return validate(params[:changes])
        end

        collected = params[:collect_changes] ? collected_commits(params, cwd) : nil
        return nil if pull_request.nil? && collected.nil?

        collected ||= { commits: [], total_count: 0 }
        changes = summarize(commits: collected[:commits], total_count: collected[:total_count], include: include_levels(params), leading_items: [pull_request].compact)
        return nil unless sent?(changes)

        announce(changes)
        return changes
      end

      def self.announce(changes)
        omitted = changes["omittedCount"] ? ", #{changes['omittedCount']} more left out to fit the limits" : ""
        UI.message("🐺 Sending #{changes['items'].length} changes to QA Wolf#{omitted}.")
      end

      def self.reject_combined(params, pull_request)
        return unless params[:collect_changes] || !pull_request.nil?

        fail_with("Pass either `changes`, or `collect_changes` and `pull_request_title`, not both. Add the pull request to `changes` yourself.")
      end

      def self.pull_request_item(params)
        title = present(params[:pull_request_title])
        description = present(params[:pull_request_description])
        fail_with("`pull_request_description` needs `pull_request_title`, because every change needs a title.") if title.nil? && !description.nil?
        return nil if title.nil?

        return {
          "description" => description.nil? ? nil : cut(description, MAX_DESCRIPTION_LENGTH),
          "kind" => "pull-request",
          "title" => cut(title, MAX_TITLE_LENGTH)
        }.compact
      end

      def self.collected_commits(params, cwd)
        since = present(params[:changes_since])
        fail_with("`collect_changes` needs `changes_since`: the commit, tag or branch the environment ran before, e.g. `origin/main` for a pull request build or `v1.2.0` for a release.") if since.nil?

        result = collect_commits(since: since, include: include_levels(params), cwd: cwd)
        unless result[:ok]
          UI.important("🐺 Not sending commits as changes: #{result[:message]}")
          return nil
        end

        return result
      end

      def self.include_levels(params)
        levels = (params[:changes_include] || INCLUDE_LEVELS).map(&:to_s)
        fail_with("`changes_include` takes only #{INCLUDE_LEVELS.join(', ')}.") unless (levels - INCLUDE_LEVELS).empty?

        return levels
      end

      def self.present(value)
        return nil unless value.kind_of?(String)
        return nil if value.strip.empty?

        return value.strip
      end

      # Checks a `changes` hash given by hand against the API's shape and
      # limits, and returns it with string keys and trimmed text. Returns nil
      # when it holds no items and no release notes, which the API treats as
      # not sent.
      def self.validate(changes)
        fail_with("`changes` must be a hash with `items`, `omittedCount` or `releaseNotes`.") unless changes.kind_of?(Hash)

        fields = known_fields(changes, CHANGES_KEYS, "changes")
        normalized = {
          "items" => validate_items(fields["items"]),
          "omittedCount" => validate_omitted_count(fields["omittedCount"]),
          "releaseNotes" => optional_text(fields["releaseNotes"], MAX_RELEASE_NOTES_LENGTH, "changes.releaseNotes")
        }.compact
        fail_with("`changes` must be at most 256 KB.") if byte_length(normalized) > MAX_BYTES

        return sent?(normalized) ? normalized : nil
      end

      def self.validate_items(items)
        return nil if items.nil?

        fail_with("`changes.items` must be an array.") unless items.kind_of?(Array)
        fail_with("`changes.items` holds at most #{MAX_ITEMS} changes.") if items.length > MAX_ITEMS
        return nil if items.empty?

        return items.each_with_index.map { |item, index| validate_item(item, "changes.items[#{index}]") }
      end

      def self.validate_omitted_count(count)
        fail_with("`changes.omittedCount` must be a whole number, 0 or more.") unless count.nil? || (count.kind_of?(Integer) && count >= 0)

        return count
      end

      def self.validate_item(item, path)
        fail_with("`#{path}` must be a hash.") unless item.kind_of?(Hash)

        fields = known_fields(item, ITEM_KEYS, path)
        fail_with("`#{path}.kind` must be one of #{KINDS.join(', ')}.") unless KINDS.include?(fields["kind"].to_s)

        return {
          "changedPaths" => validate_paths(fields["changedPaths"], "#{path}.changedPaths"),
          "description" => optional_text(fields["description"], MAX_DESCRIPTION_LENGTH, "#{path}.description"),
          "kind" => fields["kind"].to_s,
          "title" => text(fields["title"], MAX_TITLE_LENGTH, "#{path}.title"),
          "url" => validate_url(fields["url"], "#{path}.url")
        }.compact
      end

      def self.validate_paths(paths, path)
        return nil if paths.nil?

        fail_with("`#{path}` must be an array of file paths.") unless paths.kind_of?(Array)
        fail_with("`#{path}` holds at most #{MAX_PATHS_PER_ITEM} paths.") if paths.length > MAX_PATHS_PER_ITEM
        return nil if paths.empty?

        return paths.each_with_index.map { |changed_path, index| text(changed_path, MAX_PATH_LENGTH, "#{path}[#{index}]") }
      end

      def self.validate_url(url, path)
        return nil if url.nil?
        return url if url.kind_of?(String) && url.start_with?("http://", "https://") && utf16_length(url) <= MAX_URL_LENGTH

        fail_with("`#{path}` must be an http or https URL of at most #{MAX_URL_LENGTH} characters.")
      end

      # String keys, so a lane can write either `title:` or `"title" =>`. A
      # nil value counts as absent.
      def self.known_fields(hash, allowed, path)
        fields = hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
        unknown = fields.keys - allowed
        unless unknown.empty?
          fail_with("`#{path}` has unknown keys: #{unknown.join(', ')}. It takes only #{allowed.join(', ')}; there is no field for code, diffs or file contents.")
        end

        return fields.compact
      end

      def self.text(value, max, path)
        trimmed = value.kind_of?(String) ? value.strip : ""
        fail_with("`#{path}` must be a non-empty string.") if trimmed.empty?
        fail_with("`#{path}` must be at most #{max} characters.") if utf16_length(trimmed) > max

        return trimmed
      end

      def self.optional_text(value, max, path)
        return nil if value.nil?

        return text(value, max, path)
      end

      def self.fail_with(message)
        UI.user_error!("🐺 #{message}")
      end

      # The API treats a summary with no items and no release notes as not sent.
      def self.sent?(changes)
        return changes.key?("items") || changes.key?("releaseNotes")
      end

      # Reads the commits after `since` up to HEAD on the first-parent line
      # from the local git history: their messages and, when asked, the paths
      # they changed, never diffs or file contents. Refuses a shallow clone
      # rather than send part of the range.
      def self.collect_commits(since:, include:, cwd:)
        shallow = git(["rev-parse", "--is-shallow-repository"], cwd)
        return shallow unless shallow[:ok]
        return { ok: false, message: "this clone is shallow, so it may not hold every commit since #{since}. #{HISTORY_FIX}" } if shallow[:stdout].strip == "true"

        base = git(["rev-parse", "--verify", "--quiet", "--end-of-options", "#{since}^{commit}"], cwd)
        unless base[:ok]
          return { ok: false, message: "#{since.inspect} names no commit in this repository. Check it, and fetch it first if it's a tag or a remote branch, e.g. `git fetch --tags`." }
        end

        range = "#{base[:stdout].strip}..HEAD"
        count = git(["rev-list", "--count", "--first-parent", range], cwd)
        return count unless count[:ok]

        log = git(log_args(range, include.include?("paths")), cwd)
        return log unless log[:ok]

        return { ok: true, commits: parse_log(log[:stdout]), total_count: count[:stdout].strip.to_i }
      end

      def self.log_args(range, include_paths)
        return [
          "log", "--first-parent", "--max-count=#{MAX_ITEMS}", "-z", "--format=#{LOG_FORMAT}",
          # A merge lists the paths its pull request changed.
          *(include_paths ? ["--name-only", "-m"] : []),
          range
        ]
      end

      # Runs git without a shell, so arguments are never interpreted.
      def self.git(args, cwd)
        stdout, stderr, status = Open3.capture3("git", *args, chdir: cwd)
        return { ok: true, stdout: stdout.dup.force_encoding(Encoding::UTF_8).scrub } if status.success?

        return { ok: false, message: "git #{args.first} failed: #{stderr.strip}" }
      rescue SystemCallError => e
        return { ok: false, message: "git could not run: #{e.message}" }
      end

      # Reads `git log -z` output in LOG_FORMAT. With `--name-only`, each
      # record's changed paths follow, each ending in a NUL.
      def self.parse_log(stdout)
        tokens = stdout.split("\0", -1)
        starts = record_starts(tokens)
        return starts.each_with_index.map do |start, position|
          _hash, subject, body, _separator, *paths = tokens[start...(starts[position + 1] || tokens.length)]
          {
            body: body.to_s.strip,
            paths: paths.map { |path| path.delete_prefix("\n") }.reject(&:empty?),
            subject: subject.to_s.strip
          }
        end
      end

      def self.record_starts(tokens)
        return tokens.each_index.reduce([]) do |found, index|
          previous = found.last
          can_start = previous.nil? ? index.zero? : index >= previous + FIELDS_BEFORE_PATHS
          can_start && HASH_PATTERN.match?(tokens[index]) ? found + [index] : found
        end
      end

      # The summary of `leading_items` followed by the commits, newest first,
      # within the API's limits. `commits` may be the newest part of a range of
      # `total_count`; every change left out, there or to fit, is counted in
      # `omittedCount`.
      def self.summarize(commits:, total_count:, include:, leading_items: [])
        commit_items = commits
                       .reject { |commit| commit[:subject].empty? }
                       .map { |commit| commit_item(commit, descriptions: include.include?("descriptions"), paths: include.include?("paths")) }
        items = leading_items + commit_items
        total = [total_count + leading_items.length, items.length].max
        summary_of = lambda do |count|
          omitted_count = total - count
          {
            "items" => count > 0 ? items.first(count) : nil,
            "omittedCount" => omitted_count > 0 ? omitted_count : nil
          }.compact
        end
        kept = largest_fitting_count([items.length, MAX_ITEMS].min) { |count| byte_length(summary_of.call(count)) <= MAX_BYTES }
        return summary_of.call(kept)
      end

      def self.read_message(commit)
        subject = commit[:subject]
        body = commit[:body]
        if MERGE_SUBJECT_PATTERN.match?(subject) && !body.empty?
          first_line, *rest = body.sub(MERGE_REQUEST_TRAILER_PATTERN, "").strip.split("\n")
          # A GitLab merge commit can hold only the trailer.
          title = first_line.to_s.strip
          return { description: rest.join("\n").strip, kind: "pull-request", title: title.empty? ? subject : title }
        end

        return { description: body, kind: SQUASH_SUBJECT_PATTERN.match?(subject) ? "pull-request" : "commit", title: subject }
      end

      def self.commit_item(commit, descriptions:, paths:)
        message = read_message(commit)
        kept_paths = commit[:paths]
                     .reject { |path| path.strip.empty? || utf16_length(path) > MAX_PATH_LENGTH }
                     .first(MAX_PATHS_PER_ITEM)
        with_paths = lambda do |count|
          {
            "changedPaths" => paths && count > 0 ? kept_paths.first(count) : nil,
            "description" => descriptions && !message[:description].empty? ? cut(message[:description], MAX_DESCRIPTION_LENGTH) : nil,
            "kind" => message[:kind],
            "title" => cut(message[:title], MAX_TITLE_LENGTH)
          }.compact
        end
        fits = ->(count) { byte_length(with_paths.call(count)) <= MAX_BYTES_PER_ITEM }
        return with_paths.call(fits.call(kept_paths.length) ? kept_paths.length : largest_fitting_count(kept_paths.length, &fits))
      end

      # The size grows with each item kept, so the largest count that fits is
      # found by bisection.
      def self.largest_fitting_count(max)
        low = 0
        high = max
        while low < high
          middle = (low + high + 1) / 2
          if yield(middle)
            low = middle
          else
            high = middle - 1
          end
        end
        return low
      end

      # The API counts length in UTF-16 code units, as JavaScript does.
      def self.utf16_length(text)
        return text.encode(Encoding::UTF_16LE).bytesize / 2
      end

      def self.cut(text, max)
        return text if utf16_length(text) <= max

        used = 0
        return text.each_char.take_while { |char| (used += utf16_length(char)) <= max }.join
      end

      def self.byte_length(value)
        return JSON.generate(value).bytesize
      end
    end
  end
end
