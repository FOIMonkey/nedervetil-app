module SampleData
  # Invented topics and datasets for development, demos and specs. load! inserts
  # only missing records, leaving existing topics and datasets untouched.
  module Topics
    def self.in_every_nation(value)
      ::Topics::Topic::NATIONS.keys.index_with(value)
    end

    DATASETS = [
      { key: 'northmoor-abandoned-vehicles',
        publisher: 'Northmoor Statistics Office',
        title: 'Abandoned vehicles removed, by council',
        answers: 'Abandoned vehicles reported and removed each year, by ' \
                 'council',
        url: 'https://statistics.example/abandoned-vehicles', kind: 'table',
        geography: 'la', nations: ['england'], coverage: '2019–',
        frequency: 'annual', status: 'official' },
      { key: 'northmoor-recorded-crime',
        publisher: 'Northmoor Statistics Office',
        title: 'Recorded crime by police force',
        url: 'https://statistics.example/recorded-crime', kind: 'table',
        geography: 'force', nations: %w[england wales], frequency: 'quarterly',
        status: 'accredited' },
      { key: 'northmoor-police-response',
        publisher: 'Northmoor Policing Inspectorate',
        title: 'Emergency response times by force',
        url: 'https://statistics.example/police-response', kind: 'table',
        geography: 'force', nations: %w[england wales], frequency: 'annual',
        status: 'official' },
      { key: 'northmoor-agency-spend', publisher: 'Northmoor Health Department',
        title: 'Agency staff spending by trust',
        url: 'https://statistics.example/agency-spend', kind: 'table',
        geography: 'trust', nations: ['england'], frequency: 'monthly',
        status: 'management' },
      { key: 'northmoor-emergency-waits',
        publisher: 'Northmoor Health Department',
        title: 'Emergency department waiting times',
        url: 'https://statistics.example/emergency-waits', kind: 'table',
        geography: 'trust', nations: ['england'], frequency: 'monthly',
        status: 'accredited' },
      { key: 'northmoor-council-outturn',
        publisher: 'Northmoor Local Government Department',
        title: 'Council spending by service',
        url: 'https://statistics.example/council-outturn', kind: 'table',
        geography: 'la', nations: ['england'], frequency: 'annual',
        status: 'accredited' },
      { key: 'northmoor-council-tax-collection',
        publisher: 'Northmoor Local Government Department',
        title: 'Council tax collected and arrears',
        url: 'https://statistics.example/council-tax-collection', kind: 'table',
        geography: 'la', nations: ['england'], frequency: 'annual',
        status: 'accredited' },
      { key: 'northmoor-homelessness',
        publisher: 'Northmoor Local Government Department',
        title: 'Homelessness and temporary accommodation',
        url: 'https://statistics.example/homelessness', kind: 'table',
        geography: 'la', nations: ['england'], frequency: 'quarterly',
        status: 'accredited' },
      { key: 'northmoor-empty-homes',
        publisher: 'Northmoor Local Government Department',
        title: 'Empty homes by council',
        url: 'https://statistics.example/empty-homes', kind: 'table',
        geography: 'la', nations: ['england'], frequency: 'annual',
        status: 'official' },
      { key: 'northmoor-storm-overflows',
        publisher: 'Northmoor Environment Agency',
        title: 'Storm overflow spills by site',
        url: 'https://statistics.example/storm-overflows', kind: 'lookup',
        geography: 'site', nations: ['england'], frequency: 'annual',
        status: 'register' },
      { key: 'northmoor-children-in-care',
        publisher: 'Northmoor Education Department',
        title: 'Children in care by council',
        url: 'https://statistics.example/children-in-care', kind: 'table',
        geography: 'la', nations: ['england'], frequency: 'annual',
        status: 'accredited' },
      { key: 'glenmoor-parking-fines', publisher: 'Glenmoor Transport Office',
        title: 'Parking fines issued by council',
        url: 'https://statistics.example/scotland/parking-fines', kind: 'table',
        geography: 'la', nations: ['scotland'], frequency: 'annual',
        status: 'official' },
      { key: 'glenmoor-homelessness', publisher: 'Glenmoor Statistics Office',
        title: 'Homelessness in Scotland',
        url: 'https://statistics.example/scotland/homelessness',
        kind: 'collection', geography: 'la', nations: ['scotland'],
        frequency: 'biennial', status: 'accredited' }
    ].freeze

    PAGES = [
      { slug: 'streets', title: 'Streets and bins',
        summary: 'Potholes, bins, parking and food hygiene', search: 'parking',
        elsewhere_heading: 'Need to report a problem?', position: 1,
        holders: [
          { what: 'Bins, recycling, fly-tipping and street cleaning',
            key: 'bins_street', who: 'Your district or unitary council',
            nations: ['england'], to: { 'tag' => 'local_council' },
            groups: [{ 'tag' => 'district_council',
                       'label' => 'District councils' },
                     { 'tag' => 'unitary_authority',
                       'label' => 'Unitary councils' }] },
          { what: 'Local roads, potholes and street lights', key: 'roads',
            who: 'Your county or unitary council', nations: ['england'],
            to: { 'tag' => 'local_council' },
            groups: [{ 'tag' => 'county_council',
                       'label' => 'County councils' },
                     { 'tag' => 'unitary_authority',
                       'label' => 'Unitary councils' }] },
          { what: 'Food hygiene inspections', key: 'food_hygiene',
            who: 'Your district or unitary council', nations: ['england'],
            to: { 'tag' => 'local_council' },
            groups: [{ 'tag' => 'district_council',
                       'label' => 'District councils' },
                     { 'tag' => 'unitary_authority',
                       'label' => 'Unitary councils' }] },
          { what: 'Trunk roads and motorway service areas',
            who: 'Northmoor Highways Agency', nations: ['england'],
            to: { 'wdtk' => 'highways agency' } },
          { what: 'Bins, local roads and parking', key: 'bins_street',
            who: 'Your council', nations: ['scotland'],
            to: { 'tag' => 'local_council' },
            groups: [{ 'tag' => 'scottish_council',
                       'label' => 'Scottish councils' }] },
          { what: 'Bins, local roads and parking', key: 'bins_street',
            who: 'Your council', nations: ['wales'],
            to: { 'tag' => 'local_council' },
            groups: [{ 'tag' => 'welsh_council',
                       'label' => 'Welsh councils' }] },
          { what: 'Bins and council car parks', key: 'bins_street',
            who: 'Your council', nations: ['northern_ireland'],
            to: { 'tag' => 'local_council' },
            groups: [{ 'tag' => 'ni_council',
                       'label' => 'Northern Ireland councils' }] },
          { what: 'All roads, potholes and on-street parking',
            who: 'Roads Department, not the council',
            nations: ['northern_ireland'],
            to: { 'body' => 'Roads Department (Northern Ireland)' } }
        ],
        questions: [
          { text: 'How many abandoned vehicles were removed?',
            slug: 'how-many-abandoned-vehicles-were-removed',
            dataset: in_every_nation('northmoor-abandoned-vehicles'),
            nations: ['england'],
            keywords: ['abandoned vehicle',
                       'abandoned car',
                       'untaxed vehicle'] },
          { text: 'How many potholes did the council fix?',
            slug: 'how-many-potholes-did-the-council-fix',
            ask: { 'tag' => 'local_council' },
            nations: %w[england scotland wales],
            keywords: ['pothole', 'road defect'] },
          { text: 'How many parking fines were issued, and where?',
            slug: 'how-many-parking-fines-were-issued-and-where',
            dataset: { 'scotland' => 'glenmoor-parking-fines' }, partial: true,
            ask: { 'tag' => 'local_council' },
            nations: %w[england scotland wales],
            keywords: ['parking fine',
                       'parking ticket',
                       'penalty charge notice'] },
          { text: "Where are the council's CCTV cameras?",
            slug: 'where-are-the-council-s-cctv-cameras',
            ask: { 'tag' => 'local_council' }, keywords: ['CCTV'] }
        ],
        sources: [
          { label: 'Street cleaning figures by council',
            url: 'https://statistics.example/street-cleaning',
            nations: ['england'] },
          { label: 'Road condition figures',
            url: 'https://statistics.example/scotland/road-condition',
            nations: ['scotland'] }
        ],
        routes: [
          { what: 'Report a pothole', route: 'Report it online',
            to: { 'url' => 'https://report.example/pothole' },
            nations: %w[england wales] },
          { what: 'Report a missed bin collection',
            route: 'Contact your council' }
        ] },
      { slug: 'policing', title: 'Policing',
        summary: 'Crime figures, police powers and complaints',
        search: 'burglary', position: 2,
        holders: [
          { what: 'Crime, stop and search, complaints',
            who: 'Your police force', nations: %w[england wales],
            to: { 'tag' => 'police', 'wdtk' => 'police' },
            groups: [{ 'tag' => 'police', 'label' => 'Police forces' }] },
          { what: 'Complaints the force did not resolve',
            who: 'Northmoor Office for Police Conduct',
            nations: %w[england wales], to: { 'wdtk' => 'police conduct' } },
          { what: 'Crime, stop and search, complaints', who: 'Caledon Police',
            nations: ['scotland'], to: { 'body' => 'Caledon Police' } }
        ],
        questions: [
          { text: 'How many burglaries were recorded?',
            slug: 'how-many-burglaries-were-recorded',
            dataset: in_every_nation('northmoor-recorded-crime'),
            ask: { 'tag' => 'police' }, nations: %w[england wales],
            keywords: %w[burglary break-in] },
          { text: 'How fast does the force reach emergencies?',
            slug: 'how-fast-does-the-force-reach-emergencies',
            dataset: in_every_nation('northmoor-police-response'),
            partial: true, ask: { 'tag' => 'police' },
            nations: %w[england wales],
            keywords: ['response time', 'emergency call'] },
          { text: 'Does the force use facial recognition cameras?',
            slug: 'does-the-force-use-facial-recognition-cameras',
            ask: { 'tag' => 'police' }, keywords: ['facial recognition'] }
        ],
        sources: [
          { label: 'Recorded crime by force',
            url: 'https://statistics.example/recorded-crime' },
          { label: 'Street crime maps', url: 'https://crime-maps.example/' }
        ],
        routes: [
          { what: 'Complain about an officer',
            route: 'Contact your police force',
            to: { 'tag' => 'police', 'wdtk' => 'police' } },
          { what: 'Report a crime', route: 'Report it online',
            to: { 'url' => 'https://report.example/crime' } }
        ] },
      { slug: 'health', title: 'Health services',
        summary: 'Hospitals, waiting times and agency staff',
        search: 'waiting times', position: 3,
        holders: [
          { what: 'Hospitals, A&E and waiting lists', who: 'Your NHS trust',
            nations: ['england'], to: { 'tag' => 'nhs_trust' },
            groups: [{ 'tag' => 'nhs_trust', 'label' => 'NHS trusts' }] },
          { what: 'Hospitals, GP services and waiting lists',
            who: 'Your health board', nations: %w[scotland wales],
            to: { 'tag' => 'health_board', 'wdtk' => 'health board' },
            groups: [{ 'tag' => 'health_board', 'label' => 'Health boards' }] }
        ],
        questions: [
          { text: 'How much does the trust spend on agency staff?',
            slug: 'how-much-does-the-trust-spend-on-agency-staff',
            dataset: in_every_nation('northmoor-agency-spend'),
            ask: { 'tag' => 'nhs_trust' }, nations: ['england'],
            keywords: ['agency staff', 'agency nurse'] },
          { text: 'How long do patients wait in A&E?',
            slug: 'how-long-do-patients-wait-in-a-e',
            dataset: in_every_nation('northmoor-emergency-waits'),
            ask: { 'tag' => 'nhs_trust' }, nations: ['england'],
            keywords: ['accident and emergency', 'emergency department'] },
          { text: 'How much does the health board spend on agency staff?',
            slug: 'how-much-does-the-health-board-spend-on-agency-staff',
            ask: { 'tag' => 'health_board' }, nations: %w[scotland wales],
            keywords: ['agency staff', 'agency nurse'] }
        ] },
      { slug: 'spending', title: 'Public spending',
        summary: 'What councils and hospitals spend, and with whom',
        search: 'contract',
        refused: ['Names of people who received small grants',
                  'Prices in contracts still being negotiated'],
        position: 4,
        holders: [
          { what: 'Council spending, contracts and grants', who: 'Your council',
            nations: ['england'], to: { 'tag' => 'local_council' } },
          { what: 'Hospital spending and contracts', who: 'Your NHS trust',
            nations: ['england'], to: { 'tag' => 'nhs_trust' },
            groups: [{ 'tag' => 'nhs_trust', 'label' => 'NHS trusts' }] }
        ],
        questions: [
          { text: 'What does the council spend on each service?',
            slug: 'what-does-the-council-spend-on-each-service',
            dataset: in_every_nation('northmoor-council-outturn'),
            ask: { 'tag' => 'local_council' }, nations: ['england'],
            keywords: ['spending by service', 'service spending'] },
          { text: 'Who holds the contract, and when does it end?',
            slug: 'who-holds-the-contract-and-when-does-it-end',
            published: 'https://contracts.example/search',
            published_label: 'Find the contract',
            keywords: %w[contract contractor] }
        ],
        routes: [
          { what: "Question a council's accounts",
            route: 'Ask the local auditor' }
        ] },
      { slug: 'tax', title: 'Tax and benefits',
        summary: 'Income tax, Family Allowance and council tax', position: 5,
        holders: [
          { what: 'Income tax, Family Allowance and tax refunds',
            who: 'Revenue and Benefits Agency',
            to: { 'body' => 'Revenue and Benefits Agency' } },
          { what: 'Council tax bills and discounts',
            who: 'Your district or unitary council', nations: ['england'],
            to: { 'tag' => 'local_council' },
            groups: [{ 'tag' => 'district_council',
                       'label' => 'District councils' },
                     { 'tag' => 'unitary_authority',
                       'label' => 'Unitary councils' }] }
        ],
        questions: [
          { text: 'How many tax fraud cases were investigated?',
            slug: 'how-many-tax-fraud-cases-were-investigated',
            ask: { 'body' => 'Revenue and Benefits Agency' },
            keywords: ['tax fraud', 'tax evasion'] },
          { text: 'How much council tax went unpaid?',
            slug: 'how-much-council-tax-went-unpaid',
            dataset: in_every_nation('northmoor-council-tax-collection'),
            ask: { 'tag' => 'local_council' }, nations: ['england'],
            keywords: ['council tax arrears', 'unpaid council tax'] }
        ] },
      { slug: 'homes', title: 'Homes',
        summary: 'Homelessness, empty homes and housing lists',
        search: 'homeless', position: 6,
        holders: [
          { what: 'Housing lists, homelessness and empty homes', key: 'housing',
            who: 'Your district or unitary council', nations: ['england'],
            to: { 'tag' => 'local_council' },
            groups: [{ 'tag' => 'district_council',
                       'label' => 'District councils' },
                     { 'tag' => 'unitary_authority',
                       'label' => 'Unitary councils' },
                     { 'tag' => 'london_borough',
                       'label' => 'London boroughs' }] },
          { what: 'Housing lists, homelessness and empty homes', key: 'housing',
            who: 'Your council', nations: %w[scotland wales],
            to: { 'tag' => 'local_council' },
            groups: [{ 'tag' => 'scottish_council',
                       'label' => 'Scottish councils' },
                     { 'tag' => 'welsh_council',
                       'label' => 'Welsh councils' }] },
          { what: 'Housing lists and homelessness',
            who: 'Northmoor Housing Executive', nations: ['northern_ireland'],
            to: { 'wdtk' => 'housing executive' } }
        ],
        questions: [
          { text: 'How many people are homeless or in temporary accommodation?',
            slug: 'how-many-people-are-homeless-or-in-temporary-accommodation',
            dataset: { 'england' => 'northmoor-homelessness',
                       'scotland' => 'glenmoor-homelessness' },
            ask: { 'tag' => 'local_council' },
            keywords: ['homeless household',
                       'temporary accommodation',
                       'rough sleeping'] },
          { text: 'How many homes are empty?', slug: 'how-many-homes-are-empty',
            dataset: { 'england' => 'northmoor-empty-homes' },
            ask: { 'tag' => 'local_council' },
            nations: %w[england scotland wales],
            keywords: ['empty home', 'vacant home', 'standing empty'] }
        ],
        sources: [
          { label: 'Homelessness figures for Wales',
            url: 'https://statistics.example/wales/homelessness',
            nations: ['wales'] }
        ] },
      { slug: 'rivers', title: 'Rivers and coasts',
        summary: 'Flooding, sewage spills and bathing water',
        search: 'flooding', position: 7,
        holders: [
          { what: 'Flood defences and river levels',
            who: 'Northmoor Environment Agency', nations: ['england'],
            to: { 'wdtk' => 'environment agency' } },
          { what: 'Flood defences and river levels',
            who: 'Caledon Environment Protection Agency', nations: ['scotland'],
            to: { 'wdtk' => 'environment protection agency' } }
        ],
        questions: [
          { text: 'How many sewage spills were there?',
            slug: 'how-many-sewage-spills-were-there',
            dataset: in_every_nation('northmoor-storm-overflows'),
            nations: ['england'], keywords: ['sewage spill', 'storm overflow'] }
        ],
        routes: [
          { what: 'Sewage spills and water quality, from water companies',
            route: 'Ask your water company', to: { 'wdtk' => 'water company' },
            note: 'Water companies answer under the environmental rules' }
        ] },
      { slug: 'care', title: 'Care and support',
        summary: 'Children in care, adult social care and hardship help',
        search: 'care', position: 8,
        holders: [
          { what: 'Household Support Grant and adult social care',
            who: 'Your county or unitary council', nations: ['england'],
            to: { 'tag' => 'local_council' },
            groups: [{ 'tag' => 'county_council',
                       'label' => 'County councils' },
                     { 'tag' => 'unitary_authority',
                       'label' => 'Unitary councils' }] },
          { what: 'Children in care and adoption',
            who: 'Your county or unitary council', nations: ['england'],
            to: { 'tag' => 'local_council' },
            groups: [{ 'tag' => 'county_council',
                       'label' => 'County councils' },
                     { 'tag' => 'unitary_authority',
                       'label' => 'Unitary councils' }] }
        ],
        questions: [
          { text: 'How many children are in council care?',
            slug: 'how-many-children-are-in-council-care',
            dataset: in_every_nation('northmoor-children-in-care'),
            ask: { 'tag' => 'local_council' }, nations: ['england'],
            keywords: ['children in care', 'looked after children'] }
        ] }
    ].freeze

    ROWS = %i[holders questions sources routes].freeze

    module_function

    def load!
      keys = TopicDataset.pluck(:key)
      DATASETS.each do |row|
        TopicDataset.create!(row) unless keys.include?(row[:key])
      end
      slugs = TopicPage.pluck(:slug)
      pages.each { |page| page.save! unless slugs.include?(page.slug) }
    end

    def pages
      PAGES.map do |attributes|
        page = TopicPage.new(attributes.except(*ROWS))
        ROWS.each do |name|
          attributes.fetch(name, []).each_with_index do |row, position|
            page.public_send(name).build(row.merge(position: position))
          end
        end
        page
      end
    end
  end
end
