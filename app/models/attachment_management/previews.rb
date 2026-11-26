module AttachmentManagement
  # Caches sandbox-rendered page PNGs for the attachment editor workspace.
  # Cleared on confirm and expired by Retention based on mtime.
  class Previews
    MAX_PNG = 64 * 1024 * 1024

    def self.dir(attachment_id, sha256)
      Pathname(AttachmentManagement.workspace).
        join(attachment_id.to_s, sha256.to_s)
    end

    def self.clear(attachment_id, sha256 = nil)
      path = if sha256
               dir(attachment_id, sha256)
             else
               Pathname(AttachmentManagement.workspace).join(attachment_id.to_s)
             end
      FileUtils.rm_rf(path)
    end

    def self.expire(older_than:)
      root = Pathname(AttachmentManagement.workspace)
      return 0 unless root.directory?

      root.children.select(&:directory?).sum do |attachment_dir|
        gone =
          attachment_dir.children.select(&:directory?).count do |version_dir|
            last_used =
              (version_dir.children.map(&:mtime) << version_dir.mtime).max
            next false if last_used > older_than

            FileUtils.rm_rf(version_dir)
            true
          end
        attachment_dir.rmdir if attachment_dir.children.empty?
        gone
      end
    end

    attr_reader :content_type

    def initialize(attachment_id:, sha256:, content_type:, &loader)
      @dir = self.class.dir(attachment_id, sha256)
      @content_type = content_type
      @loader = loader
    end

    def kind
      return :pdf if content_type == 'application/pdf'
      return :image if AttachmentManagement.engine(job: nil).
                       coder_for(content_type)

      :none
    end

    def page_count
      case kind
      when :pdf
        pages = cached_value('pages') do
          sandboxed { |job, engine| engine.pdf_info(job.input)[:pages] }
        end
        pages.to_i
      when :image then 1
      else 0
      end
    end

    def png(page)
      raise ArgumentError, 'no such page' unless page.between?(1, page_count)

      path = @dir.join("page-#{page}.png")
      if path.exist?
        # Retention keeps the renders used recently.
        FileUtils.touch(path)
        return path
      end

      atomically(path) do |tmp|
        sandboxed do |job, engine|
          png = job.scratch('page.png')
          if kind == :pdf
            engine.render_pdf_page(job.input, page, png)
          else
            engine.render_image(job.input, engine.coder_for(content_type), png)
          end
          job.copy_out('page.png', to: tmp, max: MAX_PNG)
        end
      end
      path
    end

    def file
      path = @dir.join('file')
      unless path.exist?
        atomically(path) { |tmp| File.binwrite(tmp, @loader.call) }
      end
      path.to_s
    end

    private

    def sandboxed
      AttachmentManagement.sandboxed(input: Pathname(file),
                                     input_name: 'file') do |job|
        yield job, AttachmentManagement.engine(job: job)
      end
    end

    def cached_value(name)
      path = @dir.join("#{name}.txt")
      return path.read if path.exist?

      value = yield.to_s
      atomically(path) { |tmp| File.write(tmp, value) }
      value
    end

    def atomically(path)
      FileUtils.mkdir_p(@dir, mode: 0o700)
      tmp = @dir.join(".#{path.basename}.#{SecureRandom.hex(6)}.png").to_s
      yield tmp
      File.chmod(0o600, tmp)
      File.rename(tmp, path)
    ensure
      FileUtils.rm_f(tmp) if tmp
    end
  end
end
