module SampleData
  # Builds sample authorities, accounts, requests, documents and regulator data
  # with dates relative to load time so statuses stay current.
  class Dataset
    AUTHORITIES = {
      wrenford: ['Wrenford County Council', 'Wrenford CC',
                 'local_council county_council wrenford education roads ' \
                 'spending:https://example.org/wrenford/spending'],
      larkhollow: ['Larkhollow District Council', 'Larkhollow DC',
                   'local_council district_council wrenford housing'],
      stonemere: ['Stonemere City Council', 'Stonemere CC',
                  'local_council unitary_authority stonemere education roads ' \
                  'housing'],
      kilbranach: ['Kilbranach Council', 'Kilbranach',
                   'local_council scottish_council scotland kilbranach roads ' \
                   'sic:kilbranach'],
      hospitals: ['Wrenford Hospitals NHS Foundation Trust',
                  'Wrenford Hospitals', 'nhs_trust wrenford health'],
      icb: ['Wrenford and Stonemere Integrated Care Board',
            'Wrenford and Stonemere ICB', 'icb health wrenford stonemere'],
      health_board: ['Kilbranach Health Board', 'Kilbranach HB',
                     'health_board health scotland kilbranach ' \
                     'sic:kilbranach_health_board'],
      police: ['Brackenmoor Police', 'Brackenmoor Police', 'police emergency'],
      fire: ['Brackenmoor Fire and Rescue Service', 'Brackenmoor Fire',
             'fire_service emergency wrenford'],
      housing: ['Department for Housing Standards', 'DHS',
                'department housing'],
      university: ['University of Stonemere', 'Stonemere',
                   'university education stonemere']
    }.freeze

    # [heading, title, tag, description]
    GROUPS = [
      ['Place', 'Wrenford', 'wrenford',
       'The county council, Larkhollow, the hospitals and the fire service.'],
      ['Place', 'Stonemere', 'stonemere',
       'The city council, the university and the care board.'],
      ['Place', 'Kilbranach', 'kilbranach',
       'The council and the health board in Kilbranach.'],
      ['Type', 'Councils', 'local_council',
       'County, district, city and Scottish councils.'],
      ['Type', 'NHS and health boards', 'health',
       'Hospitals, the integrated care board and the health board.'],
      ['Type', 'Police and fire', 'emergency',
       'The police force and the fire and rescue service.'],
      ['Sector', 'Education', 'education',
       'Schools, school transport and the university.'],
      ['Sector', 'Roads and transport', 'roads',
       'Roads, streetlights, school transport and ferries.'],
      ['Sector', 'Housing', 'housing',
       'Housing standards, homelessness and temporary accommodation.']
    ].freeze

    # [authority, days ago, reference, title, outcome, name if unmatched]
    ICO_DECISIONS = [
      [:wrenford, 75, 'IC-412883-W2K7',
       'Request for home to school transport contracts', 'partly upheld'],
      [:wrenford, 210, 'IC-398114-R8D3',
       'Request for road resurfacing schedules', 'not upheld'],
      [:larkhollow, 400, 'IC-371502-L5M9',
       'Request for a waste collection contract', 'upheld'],
      [:police, 140, 'IC-405239-B3T1', 'Request for use of force figures',
       'upheld'],
      [:hospitals, 300, 'IC-382741-H6P4', 'Request for agency staffing costs',
       'not upheld'],
      [:housing, 50, 'IC-418067-D9C2',
       'Request for correspondence on building safety guidance',
       'partly upheld'],
      [:fire, 180, 'IC-401876-F4N8',
       'Request for response times to house fires', 'not upheld'],
      [:stonemere, 120, 'IC-409352-S1R6',
       'Request for school admissions appeal records', 'upheld'],
      # A name no authority matches, for the admin's names page.
      [nil, 30, 'IC-419920-X3V5', 'Request for a leisure centre contract',
       'not upheld', 'Wrenford Borough Council']
    ].freeze
    SIC_DECISIONS = [
      [:kilbranach, 95, 'Decision 041/2026',
       'Ferry timetable consultation responses', 'not upheld'],
      [:kilbranach, 260, 'Decision 177/2025', 'Harbour dredging survey',
       'partly upheld'],
      [:health_board, 150, 'Decision 098/2026',
       'Waiting times for orthopaedic surgery', 'upheld']
    ].freeze

    # The migration that adds the feeds also adds these rows; a database
    # restored from a schema dump has the tables without them.
    FEEDS = {
      'sic_statistics' => { heading: 'FOI record', tab: 'foi_record',
                            kind: 'figures', position: 10, updates: 'yearly',
                            source_line: 'From the Scottish Information ' \
                                         'Commissioner',
                            spotlights: %w[on_time requests] },
      'sic_decisions' => { heading: 'Commissioner decisions',
                           tab: 'foi_record', kind: 'decisions', position: 20,
                           updates: 'daily',
                           source_line: 'From the Scottish Information ' \
                                        'Commissioner',
                           spotlights: %w[count] },
      'ico_decisions' => { heading: 'ICO decisions', tab: 'foi_record',
                           kind: 'decisions', position: 30, updates: 'daily',
                           source_line: 'From the Information ' \
                                        'Commissioner’s Office',
                           spotlights: [] }
    }.freeze

    SALUTATION = 'Dear Nadia Holt,'.freeze
    OFFICER = 'Daniel Okoro, Information Officer, ' \
              'direct line 01632 960418'.freeze
    COUNSELLING_OFFICER = 'Priya Sandhu, Information Compliance, ' \
                          '01632 960572'.freeze
    ADDRESSEE = 'Nadia Holt, 14 Fernlea Road, Larkhollow LH2 3QP'.freeze

    def initialize(out)
      @out = out
      @at = Builder.new
      @replies = {}
    end

    def build
      accounts
      authorities
      groups
      requests
      documents
      feeds
      admin_triage
      @out.puts "Sample data: #{PublicBody.count} authorities, " \
                "#{InfoRequest.count} requests, " \
                "#{Disclosures::Document.where(state: 'published').count} " \
                'published documents'
    end

    private

    def accounts
      @at.on(150) do
        @requester = account('Nadia Holt', 'requester@example.org')
        # Batches are for trusted accounts.
        @requester.update!(trusted: true)
        @admin = account('Ruth Calder', 'admin@example.org', :admin)
        account('Annie All Roles', 'annie@localhost', :admin)
      end
    end

    def account(name, email, *roles)
      user = User.create!(name: name, email: email, password: PASSWORD,
                          email_confirmed: true)
      roles.each do |role|
        user.add_role(role) if Role.allowed_roles.include?(role.to_s)
      end
      user
    end

    def authorities
      @at.on(150) do
        @bodies = AUTHORITIES.transform_values do |name, short_name, tags|
          slug = short_name.parameterize
          PublicBody.create!(name: name,
                             short_name: short_name,
                             request_email: "foi@#{slug}.example.org",
                             home_page: "https://#{slug}.example.org",
                             tag_string: tags,
                             last_edit_editor: 'sample data',
                             last_edit_comment: 'Invented for the sample data')
        end
      end
    end

    def groups
      root = PublicBody.category_root
      GROUPS.each { |heading, *group| group(root, heading, *group) }
      AuthorityGroups::Setting.hide!(
        group(root, 'Type', 'Universities', 'university',
              'Universities and colleges.')
      )
      AuthorityGroups::WhoLine.save_for(
        @bodies[:wrenford],
        'Schools, social care, roads, libraries and waste disposal'
      )
    end

    def group(root, heading_title, title, tag, description)
      heading = Category.with_parent(root).find do |category|
        category.title == heading_title
      end
      heading ||= Category.create!(title: heading_title, description: '',
                                   parent_ids: [root.id])
      Category.create!(title: title, description: description,
                       category_tag: tag, parent_ids: [heading.id])
    end

    def requests
      waiting
      overdue
      clarification
      successful
      partly_successful
      internal_review
      not_held
      withdrawn
      extended
      scottish
      damp_and_mould
      batch
      badger
    end

    def waiting
      request = @at.on(6) do
        ask(:larkhollow, 'Fly-tipping reports and fines in 2025',
            "Please send me:\n\n" \
            "1. the number of fly-tipping reports the council received in " \
            "2025, by month\n" \
            "2. the number of fixed penalty notices issued for fly-tipping " \
            "in 2025, and how many were paid\n\n" \
            'A spreadsheet is fine.')
      end
      @at.on(5) do
        reply(request, 'ACKNOWLEDGEMENT',
              'We received your request and will reply within 20 working days.',
              ref: 'LDC-FOI-2026-0412')
      end
    end

    def overdue
      request = @at.on(45) do
        ask(:wrenford, 'Home to school transport for pupils with SEND',
            "For each of the last three school years, please tell me:\n\n" \
            "1. how many pupils with an education, health and care plan had " \
            "transport to school arranged by the council\n" \
            "2. the total cost of that transport\n" \
            '3. how many applications for transport were refused')
      end
      @at.on(8) { Deadlines::Reminder.send!(request.reload, @requester) }
    end

    def clarification
      request = @at.on(20) do
        ask(:hospitals, 'Patients cared for in corridors',
            'Please tell me how many times patients were cared for in ' \
            'corridors or other areas not designed for care, for each month ' \
            'from April 2025 to September 2026.')
      end
      @at.on(12) do
        reply(request, 'ACTION_REQUESTED',
                  'To help us find this, please tell us which sites you mean ' \
                  '(Wrenford General Hospital, Stonemere Community Hospital ' \
                  'or both), and whether you mean the emergency department ' \
                  'only or every ward. The 20 working days will start again ' \
                  'when we hear from you.',
                  ref: 'WHT-FOI-3381')
        @at.status(request, 'waiting_clarification')
      end
    end

    def successful
      request = @at.on(60) do
        ask(:larkhollow, 'Public toilets opened and closed since 2020',
            'Please send a list of the public toilets the council has run ' \
            'since January 2020, with the address of each, whether it is ' \
            'open now and the date any were closed.')
      end
      @at.on(35) do
        @replies[:toilets] = reply(
          request, 'SUBSTANTIVE',
          'Please find attached a list of the public toilets the council ' \
          'has run since 2020. We have also attached a summary of the ' \
          'cleaning contract, which we thought would help.',
          ref: 'LDC-FOI-2026-0298',
          files: [['public-toilets.csv', 'text/csv', toilets_csv],
                  ['toilet-cleaning-contract.pdf', 'application/pdf',
                   cleaning_contract_pdf]]
        )
      end
      @at.on(34) { outcome(@replies[:toilets], 'all') }
    end

    def partly_successful
      request = @at.on(70) do
        ask(:wrenford, 'Streetlight repair times',
            "For 2025, please send me:\n\n" \
            "1. the number of streetlight faults reported to the council\n" \
            "2. the average number of days to repair a fault\n" \
            '3. the repair record for each fault')
      end
      @at.on(44) do
        @streetlight_pdf, @streetlight_lines = streetlight_letter
        @replies[:streetlights] = reply(
          request, 'DECISION', 'Please find our response attached.',
          ref: 'WCC-FOI-2026-0877',
          files: [['response-streetlight-repairs.pdf', 'application/pdf',
                   @streetlight_pdf]]
        )
      end
      @at.on(43) { outcome(@replies[:streetlights], 'some') }
    end

    def internal_review
      request = @at.on(90) do
        ask(:police, 'Use of live facial recognition',
            "Please tell me:\n\n" \
            "1. each date and place the force used live facial recognition " \
            "cameras in 2025\n" \
            "2. how many people were stopped as a result, and how many were " \
            "arrested\n" \
            "3. the force's policy for using live facial recognition")
      end
      @at.on(62) do
        reply(request, 'DECISION',
                  'We hold this information, but we are withholding it under ' \
                  'section 31(1)(a) and (b) of the Freedom of Information ' \
                  'Act (law enforcement). Publishing when and where the ' \
                  'cameras are used would help people avoid them. We believe ' \
                  'the public interest favours withholding it.' \
                  "\n\nYou can ask for an internal review within 40 working " \
                  'days.',
                  ref: 'BP-FOI-26-1150')
        @at.status(request, 'rejected')
      end
      @at.on(55) do
        @at.follow_up(request,
                      'Please carry out an internal review. Other forces ' \
                      'publish the dates and places of past deployments, and ' \
                      "part 2 asks only for totals, which can't help anyone " \
                      'avoid the cameras.',
                      review: true)
      end
      @at.on(54) do
        reply(request, 'ACKNOWLEDGEMENT',
                  'We received your request for an internal review and will ' \
                  'reply within 20 working days.',
                  ref: 'BP-FOI-26-1150-IR')
        @at.status(request, 'internal_review')
      end
    end

    def not_held
      request = @at.on(50) do
        ask(:university, 'Waiting times for student counselling',
            'For the 2025/26 academic year, please tell me the average and ' \
            'longest wait between a student asking for counselling and their ' \
            'first appointment.')
      end
      # Refused and not held are one status here; the reading keeps which.
      @at.on(30) do
        @counselling_pdf, @counselling_lines = counselling_letter
        @replies[:counselling] = reply(
          request, 'DECISION', 'Please find our response attached.',
          ref: 'UoS-FOI-2026-077',
          files: [['response-counselling.pdf', 'application/pdf',
                   @counselling_pdf]]
        )
        outcome(@replies[:counselling], 'not_held')
      end
    end

    def withdrawn
      request = @at.on(40) do
        ask(:housing, 'Guidance on damp and mould in rented homes',
            'Please send any guidance the department has given councils ' \
            'since January 2025 on enforcing standards for damp and mould in ' \
            'privately rented homes.')
      end
      @at.on(33) do
        @at.follow_up(request,
                      "I'd like to withdraw this request. I've found the " \
                      'guidance on your website. Thank you.')
        request.reload
        Deadlines::Closure.close!(
          request, user: @requester,
                   final_state: 'user_withdrawn',
                   last_event_id: request.info_request_events.maximum(:id)
        )
      end
    end

    def extended
      request = @at.on(30) do
        @at.send_request(@requester, @bodies[:larkhollow],
                         'Air quality monitoring results for 2025',
                         'Please send the readings from each of the ' \
                         "council's air quality monitoring sites for 2025.",
                         law_used: 'eir')
      end
      @at.on(8) do
        reply(request, 'SUBSTANTIVE',
              'Because of the number of monitoring sites, we need more time. ' \
              'Under regulation 7(1) of the Environmental Information ' \
              'Regulations we are extending the time to reply to 40 working ' \
              'days.',
              ref: 'LDC-EIR-2026-0057')
        @at.status(request, 'waiting_response')
      end
      @at.on(7) do
        request.reload
        start = Deadlines::Stage.basis_event(request, 'response').
                created_at.to_date
        due = Deadlines::Calendar.working_days_after(
          start, Deadlines.eir_extension_days, Deadlines.regime(request)
        )
        Deadlines::Adjustment.apply!(request, stage: 'response',
                                              user: @requester, due_on: due,
                                              reason: 'eir_extension',
                                              note: 'Extended under ' \
                                                    'regulation 7(1).')
      end
    end

    def scottish
      request = @at.on(10) do
        ask(:kilbranach, 'Ferry service cancellations in 2025',
            "Please tell me how many sailings on each of the council's ferry " \
            'routes were cancelled in 2025, and the reasons recorded for the ' \
            'cancellations.')
      end
      @at.on(9) do
        @acknowledgement_pdf, @acknowledgement_lines = acknowledgement_letter
        message = reply(request, 'ACKNOWLEDGEMENT',
                        'Thank you for your request. Our acknowledgement is ' \
                        'attached.',
                        ref: 'KC-FOI-2026-0193',
                        files: [['acknowledgement.pdf', 'application/pdf',
                                 @acknowledgement_pdf]])
        @at.status(request, 'waiting_response')
        @replies[:acknowledgement] = message
      end
      @at.on(8) do
        redact_in_thread(@replies[:acknowledgement], 'acknowledgement.pdf')
      end
    end

    def damp_and_mould
      request = @at.on(86) do
        ask(:housing, 'Damp and mould complaints in temporary accommodation',
            'Please tell me how many complaints about damp and mould in ' \
            'temporary accommodation the department has received from ' \
            'councils or tenants in each quarter since April 2024.')
      end
      @at.on(85) do
        reply(request, 'ACKNOWLEDGEMENT',
              'We received your request and will reply within 20 working days.',
              ref: 'DHS-FOI-26-5521')
        @at.status(request, 'waiting_response')
      end
      @at.on(58) do
        reply(request, 'SUBSTANTIVE',
              'We received 1,214 complaints about damp and mould in ' \
              'temporary accommodation between April 2024 and March 2026. ' \
              'We do not record them by quarter, so we have given yearly ' \
              'totals: 538 in 2024/25 and 676 in 2025/26.',
              ref: 'DHS-FOI-26-5521')
        @at.status(request, 'partially_successful')
      end
    end

    def batch
      batch = @at.on(38) do
        InfoRequestBatch.create!(
          title: 'Spending on bed and breakfast accommodation',
          body: "#{OutgoingMessage::Template::BatchRequest.
            placeholder_salutation}\n\n" \
                'Please tell me how much the council spent on bed and ' \
                'breakfast accommodation for homeless households in each of ' \
                'the last three financial years, and how many households ' \
                "were placed in it at the end of each year.\n\n" \
                "Yours faithfully,\n\n#{@requester.name}",
          user: @requester,
          public_bodies: [@bodies[:larkhollow], @bodies[:stonemere]]
        ).tap do |made|
          made.create_batch!
          made.update!(sent_at: Time.current)
        end
      end
      request = batch.info_requests.find_by!(public_body: @bodies[:stonemere])
      @at.on(15) do
        @replies[:bed_and_breakfast] = reply(
          request, 'SUBSTANTIVE', 'Please find the figures attached.',
          ref: 'SCC-FOI-2026-1034',
          files: [['bed-and-breakfast-spending.csv', 'text/csv',
                   bed_and_breakfast_csv]]
        )
        @at.status(request, 'successful')
      end
      AlaveteliPro::RequestSummary.create_or_update_from(batch.reload)
    end

    def badger
      @at.on(3) do
        @at.send_request(@requester, @bodies[:university],
                         'Are you really a badger?',
                         'Is it true that you are really a badger, in fact?',
                         raw: true)
      end
    end

    def ask(key, title, text)
      @at.send_request(@requester, @bodies[key], title, text)
    end

    def reply(request, label, text, ref:, files: [])
      message = @at.reply(request, text, ref: ref, files: files)
      reading(message, label)
      message
    end

    # Seeds a completed AI prediction without calling the external worker.
    def reading(message, label)
      routine = label == 'ACKNOWLEDGEMENT'
      prediction = IncomingAttention::Prediction.
        find_or_initialize_by(incoming_message_id: message.id)
      prediction.update!(
        info_request: message.info_request,
        response_event_id: message.response_event&.id,
        status: 'complete',
        route: routine ? 'SKIP' : 'REVIEW',
        needs_check: !routine,
        eligible: true,
        restrictions: [],
        reply_labels: { (routine ? 'routine' : 'attention') => label },
        attempts: 1,
        predicted_at: Time.current
      )
    end

    def outcome(message, call)
      state = IncomingAttention::Outcome::STATES.fetch(call)
      IncomingAttention::Prediction.find_by!(incoming_message_id: message.id).
        update!(outcome_status: 'complete', outcome_call: call,
                outcome_applied_state: state, outcome_attempts: 1,
                outcome_checked_at: Time.current, auto_classified: true)
      IncomingAttention::Classification.automatically do
        message.info_request.reload.set_described_state(state)
      end
    end

    def redact_in_thread(message, filename)
      part = attachment(message, filename)
      bytes = part.body.to_s
      sha = Digest::SHA256.hexdigest(bytes)
      previews = AttachmentManagement::Previews.new(
        attachment_id: part.id, sha256: sha, content_type: part.content_type
      ) { bytes }
      box = PDF.box(72, 330, @acknowledgement_lines.fetch(ADDRESSEE))
      boxes = AttachmentManagement::Boxes.parse({ '1' => [box] }.to_json,
                                                previews.page_count)
      revision = AttachmentManagement::Revision.create!(
        foi_attachment: part, user: @requester, kind: 'pdf_redaction',
        status: 'processing', source_sha256: sha,
        source_content_type: part.content_type,
        source_filename: part.display_filename,
        instructions: { 'boxes' => boxes.transform_keys(&:to_s),
                        'by_requester' => true }
      )
      AttachmentManagement::Processor.new(revision).run
      revision.reload
      unless revision.ready?
        raise "#{filename}: the redaction is #{revision.status} " \
              "(#{revision.error})"
      end

      AttachmentManagement::Replacement.new(
        revision, editor: @requester, reason: 'Removing my name and address'
      ).apply!
    end

    def attachment(message, filename)
      SampleData.run_local_jobs
      message.reload.get_attachments_for_display.find do |part|
        part.filename == filename
      end || raise("No attachment #{filename}")
    end

    def documents
      @at.on(32) do
        toilets = document(@replies[:toilets], 'public-toilets.csv',
                           'released_records',
                           title: 'Public toilets run by the council ' \
                                  'since 2020',
                           description: 'Each public toilet the council has ' \
                                        'run since January 2020, its address ' \
                                        'and whether it is open now.')
        contract = document(@replies[:toilets], 'toilet-cleaning-contract.pdf',
                            'released_records',
                            title: 'Public toilet cleaning contract summary',
                            description: 'The contractor, value and cleaning ' \
                                         'standards for the public toilets.')
        letter = document(@replies[:streetlights],
                          'response-streetlight-repairs.pdf', 'decision_letter',
                          title: 'Streetlight repair times in 2025',
                          description: 'The council’s response on ' \
                                       'streetlight faults and repair times.')
        redact(letter, [PDF.box(98, 200, @streetlight_lines.fetch(SALUTATION)),
                        PDF.box(72, 420, @streetlight_lines.fetch(OFFICER))])
        @documents = [toilets, contract, letter]
      end
      @at.on(22) do
        letter = document(@replies[:counselling], 'response-counselling.pdf',
                          'decision_letter',
                          title: 'Student counselling waiting times',
                          description: 'The university’s response: it does ' \
                                       'not record waiting times.')
        redact(letter,
               [PDF.box(98, 200, @counselling_lines.fetch(SALUTATION)),
                PDF.box(72, 400,
                        @counselling_lines.fetch(COUNSELLING_OFFICER))])
        letter.reload
        Disclosures::ReviewSubmission.submit!(letter, user: @requester)
      end
      @at.on(14) do
        @documents << document(@replies[:bed_and_breakfast],
                               'bed-and-breakfast-spending.csv',
                               'released_records',
                               title: 'Spending on bed and breakfast ' \
                                      'accommodation',
                               description: 'Spending and households placed, ' \
                                            'for the last three financial ' \
                                            'years.')
      end
      @at.on(12) { @documents.each { |document| publish(document) } }
    end

    def document(message, filename, kind, title:, description:)
      document = Disclosures::Creation.new(user: @requester,
                                           attachment: attachment(message,
                                                                  filename),
                                           kind: kind).create!
      document.reload.update!(title: title, description: description,
                              document_date: (message.sent_at ||
                                              message.created_at).to_date,
                              updated_by: @requester)
      document
    end

    def redact(document, boxes)
      attachment = document.foi_attachment
      builder = AttachmentManagement::NewRevision.new(
        attachment, user: @requester, ability: Ability.new(@requester)
      )
      revision, = builder.build('pdf_redaction',
                                boxes: { '1' => boxes }.to_json)
      revision.save!
      AttachmentManagement::Processor.new(revision).run
      revision.reload
      unless revision.ready?
        raise "#{document.title}: redaction failed (#{revision.error})"
      end

      AttachmentManagement::Replacement.new(revision, editor: @requester).
        apply!(publish: false)
    end

    def publish(document)
      Disclosures::Publication.new(document.reload, user: @admin).publish!
    end

    def feeds
      decisions('ico_decisions', ICO_DECISIONS)
      decisions('sic_decisions', SIC_DECISIONS)
      releases
      statistics
      AuthorityFeeds::NameAlias.create!(feed: feed('ico_decisions'),
                                        name: 'Wrenford CC',
                                        public_body: @bodies[:wrenford])
    end

    # Populates /admin triage records off @requester so existing requester
    # counts stay exact.
    def admin_triage
      triage_accounts
      reported_request = triage_requests
      triage_holding_pen(reported_request)
      triage_authorities
    end

    def triage_accounts
      @at.on(90) do
        @reporter = account('Owen Mercer', 'owen@example.org')
        @reporter.update!(tag_string: 'journalist')
        @reporter.email_histories.create!(
          old_email: 'owen.old@example.org',
          new_email: @reporter.email,
          changed_at: Time.zone.now
        )
        @reporter.permission_changes.create!(
          what: 'trusted', granted: false, changed_by: @admin
        )
      end
      @at.on(45) do
        bounced = account('Tamsin Patel', 'tamsin@example.org')
        bounced.update!(
          email_bounced_at: Time.zone.now,
          email_bounce_message: '550 5.1.1 <tamsin@example.org>: ' \
                                'Recipient address rejected'
        )
        suspended = account('Gareth Finch', 'gareth@example.org')
        suspended.update!(ban_text: 'Repeated off-topic bulk mailings')
      end
      return unless User::SignIn.retain_signins?

      @at.on(4) do
        @reporter.sign_ins.create!(
          ip: '198.51.100.14',
          user_agent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X) Safari/605.1'
        )
      end
      @at.on(1) do
        @reporter.sign_ins.create!(
          ip: '198.51.100.28',
          user_agent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X) Safari/605.1'
        )
      end
    end

    def triage_requests
      reported = triage_reported_request
      triage_requires_admin_request
      triage_errored_request
      triage_hidden_request
      reported
    end

    def triage_reported_request
      req = @at.on(14) do
        @at.send_request(
          @reporter, @bodies[:wrenford], 'School crossing patrol vacancies',
          'Please tell me how many school crossing patrol posts are ' \
          'currently vacant in Wrenford, and which schools are affected.'
        )
      end
      @at.on(5) do
        @at.reply(
          req,
          'There are 7 vacant crossing patrol posts across the county. ' \
          'For site queries please call our coordinator on 07700 900123.',
          ref: 'WCC-FOI-2026-1102'
        )
        @at.status(req, 'successful')
      end
      @at.on(2) do
        req.reload.report!(
          'Personal data',
          'Reply appears to include an officer’s personal mobile number ' \
          'in the second sentence.',
          @reporter
        )
      end
      req
    end

    def triage_requires_admin_request
      req = @at.on(18) do
        @at.send_request(
          @reporter, @bodies[:larkhollow],
          'Housing repair contractor penalty clauses',
          'Please send the service credit and penalty clause schedule from ' \
          'the current council housing repairs contract.'
        )
      end
      @at.on(6) do
        @at.reply(req, 'Please see the schedule attached to this email.',
                  ref: 'LDC-FOI-2026-0884')
      end
      @at.on(3) do
        req.reload.set_described_state(
          'requires_admin', @reporter,
          'Attachment looks corrupted and will not open.'
        )
        merge_last_event_params(
          req,
          reason: 'Corrupt attachment',
          message: 'The spreadsheet attachment will not open cleanly.'
        )
      end
    end

    def triage_errored_request
      req = @at.on(7) do
        @at.send_request(
          @reporter, @bodies[:stonemere],
          'Parking enforcement camera locations',
          'Please provide the list of fixed automatic number plate ' \
          'recognition camera locations used for bus lane enforcement.'
        )
      end
      @at.on(4) do
        req.reload.set_described_state('error_message', @admin)
        merge_last_event_params(
          req,
          reason: 'Bounce',
          message: '550 5.1.1 Mailbox temporarily unavailable at authority.'
        )
      end
    end

    def triage_hidden_request
      req = @at.on(21) do
        @at.send_request(
          @reporter, @bodies[:hospitals],
          'Staff sickness absence figures 2025',
          'Please tell me how many days were lost to staff sickness absence ' \
          'in 2025, broken down by department.'
        )
      end
      @at.on(10) do
        reason = 'Contains identifiable staff medical details pending ' \
                 'redaction.'
        req.update!(prominence: 'hidden', prominence_reason: reason)
        req.log_event(
          'edit',
          editor: @admin.url_name,
          old_prominence: 'requester_only',
          prominence: 'hidden',
          prominence_reason: reason
        )
      end
    end

    def merge_last_event_params(req, extra)
      event = req.last_event
      event&.update!(params: (event.params || {}).merge(extra))
    end

    def triage_holding_pen(reported_request)
      @at.on(1, hour: 11) do
        invalid_to = reported_request.incoming_email.
                     sub(reported_request.id.to_s, 'invalid')
        deliver_holding_pen(
          from: "Information Requests <#{@bodies[:wrenford].request_email}>",
          to: invalid_to,
          subject: "RE: Freedom of Information request - " \
                   "#{reported_request.title} [WCC-FOI-2026-1102]",
          body: "Dear Owen Mercer,\n\nPlease find our corrected schedule " \
                "with personal telephone numbers removed.\n\n" \
                "Information Requests\nWrenford County Council\n",
          reason: 'address_not_found'
        )
      end
      @at.on(1, hour: 14) do
        deliver_holding_pen(
          from: "Information Requests <#{@bodies[:stonemere].request_email}>",
          to: "foi+unknown-ref@#{AlaveteliConfiguration.incoming_email_domain}",
          subject: 'FOI Ref SCC-2026-1409: Temporary housing inspection log',
          body: "Dear Requester,\n\nWe are writing to let you know we need " \
                "an extra 10 working days to consider the public interest " \
                "test on your request.\n\nStonemere City Council\n",
          reason: 'unknown_request'
        )
      end
    end

    def deliver_holding_pen(from:, to:, subject:, body:, reason:)
      pen = InfoRequest.holding_pen_request
      mail = Mail.new
      mail.from = from
      mail.to = to
      mail.subject = subject
      mail.date = Time.zone.now
      mail.message_id = "<#{SecureRandom.hex(10)}@example.org>"
      mail.content_type = 'text/plain; charset=UTF-8'
      mail.body = body
      pen.receive(Mail.from_source(mail.encoded))
      SampleData.run_local_jobs
      message = pen.reload.incoming_messages.order(:id).last
      event = pen.info_request_events.find_by(incoming_message_id: message.id)
      event&.update!(
        params: (event.params || {}).merge(rejected_reason: reason)
      )
      message
    end

    def triage_authorities
      @at.on(3) do
        PublicBody.create!(
          name: 'North Kilbranach Harbour Trust',
          short_name: 'Kilbranach Harbour',
          request_email: '',
          home_page: 'https://kilbranach-harbour.example.org',
          tag_string: 'kilbranach scotland',
          last_edit_editor: 'sample data',
          last_edit_comment: 'Missing FOI email for admin triage demo'
        )
        PublicBodyChangeRequest.create!(
          public_body: @bodies[:police],
          user: @reporter,
          public_body_email: 'information.rights@' \
                             'brackenmoor-police.example.org',
          source_url: 'https://brackenmoor-police.example.org/foi',
          notes: 'Main FOI inbox returns an auto-reply pointing to this ' \
                 'new address.'
        )
        PublicBodyChangeRequest.create!(
          public_body_name: 'Wrenford Combined Transport Authority',
          user: @requester,
          public_body_email: 'foi@wrenford-transport.example.org',
          source_url: 'https://wrenford-transport.example.org/contact',
          notes: 'Established in April 2026 under the regional devolution ' \
                 'order.'
        )
      end
    end

    # The regulators' own links aren't copied: the references are invented.
    def decisions(key, rows)
      feed = feed(key)
      AuthorityFeeds::Store.new(feed).save_items(
        rows.map do |body_key, days_ago, reference, title, outcome, name|
          body = @bodies[body_key]
          AuthorityFeeds::Decisions.row(
            feed: feed, public_body_id: body&.id,
            authority_name: name || body.name,
            decided_on: Date.current - days_ago, reference: reference,
            title: title, outcome: outcome, url: nil
          )
        end
      )
    end

    def releases
      [[:wrenford, 'Highways asset management plan 2026', 40],
       [:stonemere, 'School admissions appeals in 2025', 75],
       [:kilbranach, 'Ferry timetable review', 120]].each do |key, title, days|
        url = "https://example.org/#{@bodies[key].url_name}/#{title.parameterize}"
        AuthorityGroups::ExternalRelease.create!(
          public_body: @bodies[key], title: title, url: url,
          url_key: AuthorityGroups::ExternalRelease.url_key(url),
          released_on: Date.current - days
        )
      end
    end

    def statistics
      feed = feed(FoiStatistics::FEED)
      # The financial year that ended most recently.
      latest = Date.current.year - (Date.current.month >= 4 ? 1 : 2)
      years = [latest - 1, latest].map { |year| "#{year}-#{(year + 1) % 100}" }
      own = { years[0] => { 'requests' => 412, 'on_time' => 371, 'late' => 33,
                            'no_reply' => 8, 'full' => 198, 'some' => 104,
                            'none' => 52, 'not_held' => 41 },
              years[1] => { 'requests' => 455, 'on_time' => 419, 'late' => 30,
                            'no_reply' => 6, 'full' => 221, 'some' => 118,
                            'none' => 49, 'not_held' => 44 } }
      scotland = own.transform_values do |figures|
        figures.transform_values { |value| value * 60 }
      end
      json = { 'authorities' => { 'kilbranach' => { 'name' => 'Kilbranach ' \
                                                              'Council',
                                                    'years' => own } },
               'scotland' => scotland }.to_json
      result = AuthorityFeeds::StatisticsJson.new(json, feed).result
      AuthorityFeeds::Store.new(feed).save_figures(result.rows,
                                                   notes: result.notes)
    end

    def feed(key)
      AuthorityFeeds::Feed.find_or_create_by!(key: key) do |feed|
        feed.assign_attributes(FEEDS.fetch(key))
      end
    end

    def toilets_csv
      <<~CSV
        site,address,status,closed_on
        Market Square,"Market Square, Larkhollow LH1 2AB",Open,
        Riverside Park,"Riverside Walk, Larkhollow LH1 4DE",Closed,2023-03-31
        Bus Station,"Station Road, Larkhollow LH2 1FG",Open,
        Ashby Green,"Ashby Lane, Larkhollow LH3 7HJ",Closed,2021-10-15
        Mill Street,"Mill Street, Larkhollow LH1 9KL",Open,
      CSV
    end

    def bed_and_breakfast_csv
      <<~CSV
        financial_year,spend_gbp,households_at_31_march
        2023-24,1184200,41
        2024-25,1426900,52
        2025-26,1310450,47
      CSV
    end

    def cleaning_contract_pdf
      PDF.letter(
        ['Larkhollow District Council',
         'Public toilet cleaning contract: summary', '',
         'Contractor: Brightway Facilities Ltd',
         'Term: 1 April 2024 to 31 March 2027',
         'Annual value: GBP 186,000', '',
         'Each open toilet is cleaned twice a day, and checked again in the',
         'evening between May and September.',
         'Faults reported by the public are fixed within two working days.']
      ).first
    end

    def counselling_letter
      PDF.letter(
        ['University of Stonemere', 'Information Compliance', '',
         'Our reference: UoS-FOI-2026-077', '', SALUTATION, '',
         'Waiting times for student counselling', '',
         "We don't hold this information. Our counselling service records",
         'appointments, but not the date a student first asks for one, so we',
         "can't work out waiting times. Working them out would mean making a",
         'new record, which the Freedom of Information Act does not require.',
         '', 'If you are unhappy with this response, you can ask for an',
         'internal review within 40 working days.', '', 'Yours sincerely,',
         '', COUNSELLING_OFFICER]
      )
    end

    def acknowledgement_letter
      PDF.letter(
        ['Kilbranach Council', 'Freedom of Information', '',
         'Our reference: KC-FOI-2026-0193', '', ADDRESSEE, '', SALUTATION, '',
         'Thank you for your request about ferry service cancellations,',
         "which we received on #{I18n.l(Date.current, format: '%-d %B %Y')}.",
         'We will respond within 20 working days, as the Freedom of',
         'Information (Scotland) Act 2002 requires.', '', 'Yours sincerely,',
         '', 'Freedom of Information Team']
      )
    end

    def streetlight_letter
      PDF.letter(
        ['Wrenford County Council', 'Information Requests', '',
         'Our reference: WCC-FOI-2026-0877', '',
         SALUTATION, '',
         'Streetlight repair times', '',
         'In 2025 we received 1,942 reports of streetlight faults.',
         'The average time to repair a fault was 9 working days.', '',
         'You also asked for the repair record for each fault. We have not',
         'provided these: finding and extracting them would cost more than',
         'the appropriate limit, so section 12 of the Freedom of Information',
         'Act applies. If you narrow your request, for example to one ward,',
         'we may be able to help.', '',
         'If you are unhappy with this response, you can ask for an internal',
         'review within 40 working days.', '',
         'Yours sincerely,', '', OFFICER]
      )
    end
  end
end
