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
                                       description: "What the deployment changed, as `{ items: [{ kind:, title:, description:, changedPaths:, url: }], omittedCount:, releaseNotes: }`, where `kind` is `pull-request` or `commit`. There is no field for code, diffs or file contents",
                                       optional: true,
                                       type: Hash),
          FastlaneCore::ConfigItem.new(key: :collect_changes,
                                       description: "Add the commits after `changes_since` up to HEAD from the local git history to `changes`, with their messages and changed file paths, never diffs or file contents. Off by default. A shallow clone adds no commits and warns",
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
                                       type: Array)
        ]
      end

      # What the deployment changed: `changes` as given, followed by the
      # commits collected from git that it doesn't already hold. Nil when
      # neither is set, so the report carries no `changes`. Collecting never
      # fails the lane: when git can't answer, it warns and adds no commits.
      def self.from_options(params, cwd:)
        given = params[:changes].nil? ? {} : validate(params[:changes])
        collected = params[:collect_changes] ? collected_commits(params, cwd) : nil
        changes = collected.nil? ? given : add_commits(given, collected, include_levels(params))
        return nil unless sent?(changes)

        announce(changes) unless collected.nil?
        return changes
      end

      def self.add_commits(given, collected, include)
        given_items = given["items"] || []
        commits = collected[:commits].reject { |commit| already_given?(commit, given_items) }
        return summarize(
          commits: commits,
          total_count: collected[:total_count] - (collected[:commits].length - commits.length) + (given["omittedCount"] || 0),
          include: include,
          leading_items: given_items,
          release_notes: given["releaseNotes"]
        )
      end

      # A commit is already given when an item links to it by its sha, or,
      # for a merged pull request, by its number.
      def self.already_given?(commit, items)
        number = pull_request_number_of(commit)
        return items.any? do |item|
          url = item["url"].to_s
          links_to_sha?(url, commit[:hash]) || (!number.nil? && links_to_pull_request?(url, number))
        end
      end

      def self.links_to_sha?(url, hash)
        return url.scan(/[0-9a-f]{7,64}/i).any? { |token| hash.to_s.start_with?(token.downcase) }
      end

      def self.links_to_pull_request?(url, number)
        return %r{/(?:pull|merge_requests)/#{number}(?:[/?#]|\z)}.match?(url)
      end

      def self.pull_request_number_of(commit)
        match = commit[:subject].match(/\AMerge pull request #(\d+)/) ||
                commit[:subject].match(/\(#(\d+)\)\z/) ||
                commit[:body].match(/^See merge request \S+!(\d+)$/)
        return match && match[1]
      end

      def self.announce(changes)
        omitted = changes["omittedCount"] ? ", #{changes['omittedCount']} more left out to fit the limits" : ""
        UI.message("🐺 Sending #{(changes['items'] || []).length} changes to QA Wolf#{omitted}.")
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
      # limits, and returns it with string keys and trimmed text. A blank
      # optional text counts as absent.
      def self.validate(changes)
        fail_with("`changes` must be a hash with `items`, `omittedCount` or `releaseNotes`.") unless changes.kind_of?(Hash)

        fields = known_fields(changes, CHANGES_KEYS, "changes")
        normalized = {
          "items" => validate_items(fields["items"]),
          "omittedCount" => validate_omitted_count(fields["omittedCount"]),
          "releaseNotes" => optional_text(fields["releaseNotes"], MAX_RELEASE_NOTES_LENGTH, "changes.releaseNotes")
        }.compact
        fail_with("`changes` must be at most 256 KB.") if byte_length(normalized) > MAX_BYTES

        return normalized
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
        return nil if value.nil? || (value.kind_of?(String) && value.strip.empty?)

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
          hash, subject, body, _separator, *paths = tokens[start...(starts[position + 1] || tokens.length)]
          {
            body: body.to_s.strip,
            hash: hash,
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
      # and `release_notes`, within the API's limits. `commits` may be the
      # newest part of a range of `total_count`; every change left out, there
      # or to fit, is counted in `omittedCount`.
      def self.summarize(commits:, total_count:, include:, leading_items: [], release_notes: nil)
        commit_items = commits
                       .reject { |commit| commit[:subject].empty? }
                       .map { |commit| commit_item(commit, descriptions: include.include?("descriptions"), paths: include.include?("paths")) }
        items = leading_items + commit_items
        total = [total_count + leading_items.length, items.length].max
        summary_of = lambda do |count|
          omitted_count = total - count
          {
            "items" => count > 0 ? items.first(count) : nil,
            "omittedCount" => omitted_count > 0 ? omitted_count : nil,
            "releaseNotes" => release_notes
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
