require 'spec_helper'

# Compares normalizes with LegacyStripAttributes; new text columns need a rule.
RSpec.describe 'Whitespace normalisation' do
  awkward_values = [
    ' a ', 'a', "\ta b\n", "\u00A0a\u2003", "\u200Ba\uFEFF", "\u3000x\u180E",
    "a\r\nb", "a\n\nb", "a \t  b", "ünï  cødé ", '   ', '', "\u200B"
  ]

  # Per-column LegacyStripAttributes options (:untouched = left as-is,
  # :skip = aliased or overwritten by a validation callback).
  legacy_rules = {
    User => ->(column) do
      column == 'otp_backup_codes' ? :skip : { allow_empty: true }
    end,
    InfoRequest => ->(column) do
      case column
      when 'title' then { replace_newlines: true, collapse_spaces: true }
      when 'idhash' then :skip # computed from the id
      else { allow_empty: true }
      end
    end,
    DraftInfoRequest => ->(_column) { {} },
    SpamAddress => ->(_column) { {} },
    OutgoingMessage => ->(column) do
      column == 'prominence_reason' ? {} : { allow_empty: true }
    end,
    IncomingMessage => ->(column) do
      column == 'prominence_reason' ? {} : :untouched
    end,
    FoiAttachment => ->(column) do
      column == 'prominence_reason' ? {} : :untouched
    end,
    PublicBody => ->(column) do
      column == 'request_email' ? { allow_empty: true } : {}
    end,
    PublicBody::Translation => ->(column) do
      column == 'request_email' ? { allow_empty: true } : {}
    end
  }

  factories = {
    User => -> { FactoryBot.create(:user) },
    InfoRequest => -> { FactoryBot.create(:info_request) },
    DraftInfoRequest => -> { FactoryBot.create(:draft_info_request) },
    SpamAddress => -> { FactoryBot.create(:spam_address) },
    OutgoingMessage => -> { FactoryBot.create(:initial_request) },
    IncomingMessage => -> { FactoryBot.create(:incoming_message) },
    FoiAttachment => -> { FactoryBot.create(:body_text) },
    PublicBody => -> { FactoryBot.create(:public_body) },
    PublicBody::Translation => -> do
      FactoryBot.create(:public_body).translations.first
    end
  }

  text_columns = ->(model) do
    columns = model.columns.
      select { |c| %i[string text].include?(c.type) && !c.array }.map(&:name)
    columns |= model.translated_attribute_names.map(&:to_s) if
      model.respond_to?(:translated_attribute_names)
    columns.sort
  end

  def value_after_validation(record, column, value)
    record.reload
    record[column] = value.dup
    record.valid?
    record.read_attribute(column)
  end

  untouched_values = [' a ', "\ta b\n", "\u200Ba\uFEFF"]

  legacy_rules.each do |model, rule|
    describe model.name do
      let(:record) { factories.fetch(model).call }

      text_columns.call(model).each do |column|
        options = rule.call(column)
        next if options == :skip

        if options == :untouched
          it "leaves whitespace around #{column}" do
            aggregate_failures do
              untouched_values.each do |value|
                expect(value_after_validation(record, column, value)).
                  to eq(value), "for #{value.inspect}"
              end
            end
          end
        else
          it "tidies #{column} as strip_attributes(#{options}) did" do
            aggregate_failures do
              awkward_values.each do |value|
                expect(value_after_validation(record, column, value)).
                  to eq(LegacyStripAttributes.strip(value.dup, **options)),
                     "for #{value.inspect}"
              end
            end
          end
        end
      end
    end
  end

  # A normalizes naming a column that has gone would quietly make a virtual
  # attribute that is never stored.
  it 'normalizes only columns that exist' do
    aggregate_failures do
      legacy_rules.each_key do |model|
        expect(model.normalized_attributes.map(&:to_s) - model.column_names).
          to be_empty, model.name
      end
    end
  end

  describe 'stored values' do
    def stored(record, column, value)
      record.reload
      record.public_send("#{column}=", value)
      record.save!
      record.reload.read_attribute(column)
    end

    it 'stores the tidied value for each model' do
      aggregate_failures do
        expect(stored(FactoryBot.create(:user), :email_bounce_message,
                      "  Me\n")).to eq('Me')
        expect(stored(FactoryBot.create(:user), :email_bounce_message,
                      " \n ")).to eq('')
        expect(stored(FactoryBot.create(:info_request), :title,
                      " One\r\n\r\ntwo \t three\u200B ")).
          to eq('One two three')
        draft = FactoryBot.create(:draft_info_request)
        expect(stored(draft, :title, "\u00A0Draft ")).to eq('Draft')
        expect(stored(draft, :body, " \n")).to be_nil
        expect(stored(FactoryBot.create(:spam_address), :email,
                      " spam@example.org\n")).to eq('spam@example.org')
        expect(stored(FactoryBot.create(:initial_request), :body,
                      "\nDear Sir,\n\nYours  \n")).
          to eq("Dear Sir,\n\nYours")
        expect(stored(FactoryBot.create(:incoming_message),
                      :prominence_reason, '  ')).to be_nil
        expect(stored(FactoryBot.create(:body_text), :prominence_reason,
                      ' Spam ')).to eq('Spam')
      end
    end
  end

  describe 'translated authority fields' do
    let!(:body) { FactoryBot.create(:public_body) }

    def translation(body, locale)
      body.translations.reload.find { |t| t.locale.to_s == locale.to_s }
    end

    it 'tidies a value assigned in the current locale before validating' do
      body.name = "\u00A0Office \u200B"
      body.short_name = '   '
      body.valid?
      expect(body).to have_attributes(name: 'Office', short_name: nil)
    end

    it 'treats a name that is only invisible characters as missing' do
      body.name = "\u200B"
      expect(body).not_to be_valid
      expect(body.errors).to include(:name)
    end

    it 'stores tidied values in the translation and the version' do
      body.update!(name: ' Office ', request_email: " foi@example.org\n",
                   home_page: ' ', publication_scheme: '')
      expect(translation(body, :en)).to have_attributes(
        name: 'Office', first_letter: 'O', request_email: 'foi@example.org',
        publication_scheme: nil
      )
      expect(body.reload.home_page).to be_nil
      expect(body.versions.last).to have_attributes(
        name: 'Office', request_email: 'foi@example.org'
      )
    end

    it 'keeps a blank request email as an empty string' do
      body.update!(request_email: '  ')
      expect(translation(body, :en).request_email).to eq('')
    end

    it 'tidies a value assigned in another locale' do
      AlaveteliLocalization.with_locale(:es) do
        body.name = ' El Cuerpo '
        body.short_name = "\t"
      end
      body.save!
      expect(translation(body, :es)).to have_attributes(
        name: 'El Cuerpo', short_name: nil, first_letter: 'E'
      )
    end

    it 'tidies values given as nested translation attributes' do
      body.translations_attributes = {
        '1' => { locale: 'es', name: ' El Body ', request_email: ' ' }
      }
      body.save!
      expect(translation(body, :es)).to have_attributes(
        name: 'El Body', request_email: ''
      )
    end
  end

  describe 'differences from strip_attributes' do
    it 'tidies a draft saved without validation' do
      draft = FactoryBot.build(:draft_info_request, title: ' Draft ',
                                                    body: "  \n")
      draft.save!(validate: false)
      expect(draft.reload).to have_attributes(title: 'Draft', body: nil)
    end

    it 'derives a translation URL name from the tidied short name' do
      translation = FactoryBot.create(:public_body, name: 'Office').
        translations.first
      translation.short_name = '   '
      expect(translation.url_name).to eq('office')
    end

    it 'leaves a stored value alone until it is assigned again' do
      user = FactoryBot.create(:user)
      User.where(id: user.id).update_all("email_bounce_message = ' Me '")
      user.reload.update!(name: 'New Name')
      expect(user.reload.email_bounce_message).to eq(' Me ')
    end

    it 'tidies the values given to a query' do
      FactoryBot.create(:spam_address, email: 'spam@example.org')
      expect(SpamAddress.spam?(' spam@example.org ')).to be(true)
    end

    it 'keeps a request URL title when only whitespace is added' do
      title = 'Recycling collections by street'
      FactoryBot.create(:info_request, title: title)
      request = FactoryBot.create(:info_request, title: title)
      FactoryBot.create(:info_request, title: title)
      slug = 'recycling_collections_by_street_2'
      expect(request.url_title).to eq(slug)
      request.update!(title: "#{title} ")
      expect(request.reload.url_title).to eq(slug)
    end

    it 'gives the sign-up spam score the tidied email domain' do
      user = User.new(email: ' spam@163.com  ')
      expect(user.email_domain).to eq('163.com')
    end
  end
end
