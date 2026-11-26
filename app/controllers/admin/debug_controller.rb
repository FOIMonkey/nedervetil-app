# Displays deployment diagnostics to admins, including the current git commit,
# branch, application version and sanitised AlaveteliConfiguration.
class Admin::DebugController < AdminController
  def index
    @admin_current_user = admin_current_user
    @current_commit = Statistics::General.new.to_h[:alaveteli_git_commit]
    @current_branch = `git branch | perl -ne 'print $1 if /^\\* (.*)/'`
    @current_version = ALAVETELI_VERSION
    # rubocop:disable Layout/LineLength -- a shell command with a regex
    repo = `git remote show origin -n | perl -ne 'print $1 if m{Fetch URL: .*github\\.com[:/](.*)\\.git}'`
    # rubocop:enable Layout/LineLength
    @github_origin = "https://github.com/#{repo}/tree/"
    @alaveteli_configuration = AlaveteliConfiguration.to_sanitized_hash
  end
end
