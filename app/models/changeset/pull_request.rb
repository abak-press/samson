class Changeset::PullRequest
  # Matches a section heading named "Risks".
  RISKS_SECTION = /#+\s+Risks.*\n/i

  # Matches URLs to JIRA issues.
  JIRA_ISSUE = %r[https://jira\.railsc\.ru/browse/[\w-]+]

  # Matches "VOICE-1234" or "[VOICE-1234]"
  JIRA_CODE = %r[(\[)*([a-zA-Z]+)-((\d)+)(\])*]

  # Finds the pull request with the given number.
  #
  # repo   - The String repository name, e.g. "zendesk/samson".
  # number - The Integer pull request number.
  #
  # Returns a ChangeSet::PullRequest describing the PR or nil if it couldn't
  #   be found.
  def self.find(repo, number)
    data = Rails.cache.fetch([self, repo, number].join("-")) do
      GITHUB.pull_request(repo, number)
    end

    new(repo, data)
  rescue Octokit::NotFound
    nil
  end

  attr_reader :repo

  def initialize(repo, data)
    @repo, @data = repo, data
  end

  delegate :number, :title, :additions, :deletions, to: :@data

  def title_without_jira
    title.gsub(JIRA_CODE, "").strip
  end

  def url
    "https://#{Rails.application.config.samson.github.web_url}/#{repo}/pull/#{number}"
  end

  def reference
    "##{number}"
  end

  def users
    users = [@data.user, @data.merged_by]
    users.compact.map {|user| Changeset::GithubUser.new(user) }.uniq
  end

  def risky?
    risks.present?
  end

  def risks
    return @risks if defined?(@risks)
    @risks = @data.body.to_s.split(RISKS_SECTION, 2)[1].to_s.strip.presence
    @risks = nil if @risks =~ /\A\s*\-?\s*None\Z/i
    @risks
  end

  def jira_issues
    @jira_issues ||= parse_jira_issues!
  end

  private

  def parse_jira_issues!
    body.scan(JIRA_ISSUE).map do |match|
      Changeset::JiraIssue.new(match)
    end
  end

  def body
    @data.body.to_s
  end
end
