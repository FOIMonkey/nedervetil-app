namespace :sandbox do
  desc 'Check that this process would run document converters in the sandbox'
  task check: :environment do
    results = []
    check = ->(name, ok, detail) { results << [name, ok, detail] }

    mode = AlaveteliSandbox.mode
    check.call('mode', mode == :required, "SANDBOX_CONVERTERS is #{mode}")
    disabled = AlaveteliSandbox.disabled?
    check.call('kill switch', !disabled,
               disabled ? 'CONVERTERS_DISABLED is on' : 'off')

    begin
      AlaveteliSandbox.check_configuration!
      check.call('configuration', true, 'valid')
    rescue AlaveteliSandbox::ConfigurationError => e
      check.call('configuration', false, e.message)
    end

    cells = AlaveteliSandbox::Cell.configured?
    problem = AlaveteliSandbox.volume_problem
    kept = cells ? 'shared with the cells only' : 'private'
    check.call('volume', problem.nil?,
               problem || "#{AlaveteliSandbox.volume} is a tmpfs, #{kept}")

    self_test = ->(name, where, cell: nil) do
      AlaveteliSandbox.self_test(cell: cell)
      check.call(name, AlaveteliSandbox.required?,
                 "ran /usr/bin/true #{where}")
    rescue AlaveteliSandbox::Error, SystemCallError => e
      error = e.class.name.demodulize
      check.call(name, false, "#{error}: #{e.message}")
    end

    if cells
      AlaveteliSandbox::Cell.sockets.each do |cell, socket|
        self_test.call("#{cell} cell", "in the sandbox, at #{socket}",
                       cell: cell)
      end
    else
      bwrap = AlaveteliSandbox.bwrap
      check.call('bwrap', File.executable?(bwrap), bwrap)

      # Kernel sysctls required for unprivileged bubblewrap (skipped if absent).
      {
        'user/max_user_namespaces' => ->(value) { value != '0' },
        'kernel/unprivileged_userns_clone' => ->(value) { value != '0' },
        'kernel/apparmor_restrict_unprivileged_userns' =>
          ->(value) { value == '0' }
      }.each do |setting, needed|
        path = "/proc/sys/#{setting}"
        next unless File.exist?(path)

        value = File.read(path).strip
        check.call(setting.tr('/', '.'), needed.call(value), value)
      end

      sandboxed = AlaveteliSandbox.required?
      self_test.call('self-test',
                     sandboxed ? 'in the sandbox' : 'directly (mode off)')
      if sandboxed
        begin
          listing = AlaveteliSandbox.job do |job|
            job.run(AlaveteliSandbox::ImagePolicy::PROGRAM, '-list', 'policy',
                    timeout: 30).stdout
          end
          problem = AlaveteliSandbox::ImagePolicy.problem(listing)
          check.call('ImageMagick policy', problem.nil?,
                     problem || 'imagemagick-policy.xml in force')

        rescue AlaveteliSandbox::Error, SystemCallError => e
          error = e.class.name.demodulize
          check.call('ImageMagick policy', false, "#{error}: #{e.message}")
        end
      end
    end

    if AlaveteliSandbox.required?
      begin
        PDFRedactor::Isolated.self_test
        where = cells ? 'the PDF cell' : 'the sandbox'
        check.call('pdf worker', true, "ran on a tiny PDF in #{where}")
      rescue PDFRedactor::Error => e
        check.call('pdf worker', false, e.message)
      end
    else
      check.call('pdf worker', true, 'not needed: masking runs in this process')
    end

    if AlaveteliSandbox.required?
      begin
        OfficePackage::Isolated.self_test
        where = cells ? 'the Office cell' : 'the sandbox'
        check.call('office worker', true, "read a tiny document in #{where}")
      rescue AlaveteliSandbox::Error => e
        error = e.class.name.demodulize
        check.call('office worker', false, "#{error}: #{e.message}")
      end
    else
      check.call('office worker', true,
                 'not needed: Office files are read in this process')
    end

    begin
      MailHandler.outlook_self_test
      where = if cells
                'the mail cell'
              else
                AlaveteliSandbox.required? ? 'the sandbox' : 'this process'
              end
      check.call('outlook converter', true,
                 "converted a tiny message in #{where}")
    rescue MailHandler::ReadRefused => e
      check.call('outlook converter', false, e.message)
    end

    begin
      MailHandler::Reading.self_test
      where = if cells
                'the mail cell'
              else
                AlaveteliSandbox.required? ? 'the sandbox' : 'this process'
              end
      check.call('mail read', true, "read a tiny mail in #{where}")
    rescue MailHandler::ReadRefused, MailHandler::TooComplex => e
      check.call('mail read', false, e.message)
    end

    puts "Sandbox check (#{AlaveteliSandbox.context})"
    results.each do |name, ok, detail|
      puts format('%-4s %s: %s', ok ? 'PASS' : 'FAIL', name, detail)
    end

    abort 'Sandbox check failed' unless results.all? { |_, ok, _| ok }
  end
end
