require 'open3'

module Statistics
  # High-level site statistics and version information
  class General
    def self.git_commit
      @git_commit ||=
        begin
          out, status = Open3.capture2('git', 'log', '-1', '--format=%H')
          status.success? ? out.strip : ''
        rescue SystemCallError
          ''
        end
    end

    def to_h
      {
        alaveteli_git_commit: alaveteli_git_commit,
        alaveteli_version: ALAVETELI_VERSION,
        ruby_version: RUBY_VERSION,
        visible_public_body_count: PublicBody.visible.count,
        private_request_count:
          InfoRequest.where(prominence: 'requester_only').count,
        request_via_batch_count: InfoRequest.via_batch.count,
        batch_count: InfoRequestBatch.count,
        confirmed_user_count: User.active.where(email_confirmed: true).count,
        public_body_change_request_count: PublicBodyChangeRequest.count,
        request_classification_count: RequestClassification.count
      }
    end

    def to_json(*)
      to_h.to_json
    end

    def alaveteli_git_commit
      self.class.git_commit
    end
  end
end
