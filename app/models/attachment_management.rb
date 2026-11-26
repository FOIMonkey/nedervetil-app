# In-place attachment redaction and editing screens and working-copy tools.
module AttachmentManagement
  REQUESTER_ACCESS = %w[none redact replace].freeze
  REVIEW_DRAFT_RETENTION = 7.days

  mattr_accessor :max_bytes, default: 50.megabytes

  # Scratch dir for renders (never web-served; purged on confirm/Retention).
  mattr_accessor :workspace,
                 default: Rails.root.join('tmp', 'attachment_management')

  mattr_writer :requester_access, :draft_retention, :preview_retention

  # Requester editing mode: redact (hide only), replace (full edit), or none.
  # Admins always have full access.
  def self.requester_access
    value = (@@requester_access ||= nil) || # rubocop:disable Style/ClassVars -- mattr_writer keeps it here; SettingsHelpers puts it back
            AlaveteliConfiguration.attachment_management_requester_access
    REQUESTER_ACCESS.include?(value.to_s) ? value.to_s : 'none'
  end

  # Keep drafts for REVIEW_DRAFT_RETENTION when admin review may be pending.
  def self.draft_retention
    override = (@@draft_retention ||= nil) # rubocop:disable Style/ClassVars -- mattr_writer keeps it here; SettingsHelpers puts it back
    return override if override
    return REVIEW_DRAFT_RETENTION unless Disclosures.requester_editing?

    AlaveteliConfiguration.attachment_management_draft_hours.to_f.hours
  end

  def self.preview_retention
    (@@preview_retention ||= nil) || # rubocop:disable Style/ClassVars -- mattr_writer keeps it here; SettingsHelpers puts it back
      AlaveteliConfiguration.attachment_management_preview_hours.to_f.hours
  end

  def self.engine(job:)
    Engines::Raster.new(job: job)
  end

  def self.sandboxed(input: nil, input_name: 'input', &block)
    AlaveteliSandbox.job(input: input, input_name: input_name, &block)
  rescue AlaveteliSandbox::Error => e
    raise Command::Failed, e.message
  end

  # Reads sandbox output via Job#open_file (no symlinks, regular file, size
  # cap); falls back to direct reads only when job is nil (sandbox off).
  def self.open_output(path, job:, max: max_bytes, &block)
    return File.open(path, 'rb', &block) unless job

    job.open_file(path, max: max, &block)
  rescue AlaveteliSandbox::Error => e
    raise Command::Failed, e.message
  end

  def self.read_output(path, job:, max: max_bytes)
    return File.binread(path) unless job

    job.read_file(path, max: max)
  rescue AlaveteliSandbox::Error => e
    raise Command::Failed, e.message
  end

  def self.copy_output(path, to:, job:, max: max_bytes)
    return FileUtils.cp(path, to) unless job

    job.copy_file(path, to: to, max: max)
  rescue AlaveteliSandbox::Error => e
    raise Command::Failed, e.message
  end
end
