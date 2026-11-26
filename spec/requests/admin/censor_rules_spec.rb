require 'spec_helper'

RSpec.describe 'Admin censor rules', type: :request do
  before { sign_in users(:admin_user) }

  def page
    Nokogiri::HTML(response.body)
  end

  def new_rule_form
    page.at_css('form#new_censor_rule')
  end

  def applies_to_links
    page.css('.well a').map { |link| link['href'] }
  end

  def applies_to_everything?
    page.at_css('.well strong')&.text == 'everything' &&
      page.css('.well a').empty?
  end

  def edit_form_for(censor_rule)
    page.at_css("form[action='#{admin_censor_rule_path(censor_rule)}']")
  end

  # NOTE: bodies are routed with body_id, not public_body_id.
  subjects = {
    'request_id' => { factory: :info_request,
                      rule_factory: :info_request_censor_rule,
                      admin_path: :admin_request_path,
                      rules_path: :admin_request_censor_rules_path,
                      new_path: :new_admin_request_censor_rule_path },
    'user_id' => { factory: :user,
                   rule_factory: :user_censor_rule,
                   admin_path: :admin_user_path,
                   rules_path: :admin_user_censor_rules_path,
                   new_path: :new_admin_user_censor_rule_path },
    'body_id' => { factory: :public_body,
                   rule_factory: :public_body_censor_rule,
                   admin_path: :admin_body_path,
                   rules_path: :admin_body_censor_rules_path,
                   new_path: :new_admin_body_censor_rule_path }
  }

  rules = {
    'a global censor rule' => [:global_censor_rule, nil],
    'a CensorRule with an associated InfoRequest' =>
      [:info_request_censor_rule, :admin_request_path],
    'a CensorRule with an associated User' =>
      [:user_censor_rule, :admin_user_path],
    'a CensorRule with an associated PublicBody' =>
      [:public_body_censor_rule, :admin_body_path]
  }

  def subject_page(censor_rule, admin_path)
    return admin_censor_rules_path unless admin_path

    send(admin_path, censor_rule.censorable)
  end

  describe 'GET index' do
    let!(:global_rules) do
      FactoryBot.create_list(:global_censor_rule, 3)
    end

    before do
      FactoryBot.create(:info_request_censor_rule)
      FactoryBot.create(:public_body_censor_rule)
      FactoryBot.create(:user_censor_rule)
      get admin_censor_rules_path
    end

    it 'shows the global censor rules page' do
      expect(response).to be_successful
      expect(page.at_css('h1').text).to eq('Global Censor Rules')
    end

    it 'lists only the global censor rules' do
      ids = page.css('.censor-rule-list td.id').map { |cell| cell.text.to_i }
      expect(ids).to match_array(global_rules.map(&:id))
    end
  end

  describe 'GET new' do
    context 'global censor rule' do
      before { get new_admin_censor_rule_path }

      it 'shows an empty form that posts to the global rules' do
        expect(response).to be_successful
        expect(page.at_css('h1').text).to eq('New censor rule')
        expect(new_rule_form['action']).to eq(admin_censor_rules_path)
        expect(new_rule_form.at_css('#censor_rule_text')['value']).to be_nil
      end

      it 'does not associate the censor rule with a censorable' do
        expect(applies_to_everything?).to be(true)
      end
    end

    subjects.each do |param, kind|
      context "#{param} param" do
        let(:censorable) { FactoryBot.create(kind[:factory]) }

        before { get send(kind[:new_path], censorable) }

        it 'shows an empty form that posts to the rules for the record' do
          expect(response).to be_successful
          expect(page.at_css('h1').text).to eq('New censor rule')
          expect(new_rule_form['action']).
            to eq(send(kind[:rules_path], censorable))
          expect(new_rule_form.at_css('#censor_rule_text')['value']).
            to be_nil
        end

        it 'associates the record named by the param with the rule' do
          expect(applies_to_links).
            to include(send(kind[:admin_path], censorable))
          expect(applies_to_everything?).to be(false)
        end
      end
    end
  end

  describe 'POST create' do
    context 'a global censor rule' do
      let(:censor_rule_params) do
        params = FactoryBot.attributes_for(:global_censor_rule)
        # last_edit_editor gets set in the controller
        params.delete(:last_edit_editor)
        params
      end

      def create_censor_rule
        post admin_censor_rules_path,
             params: { censor_rule: censor_rule_params }
      end

      it 'creates a global rule edited by the current admin' do
        expect { create_censor_rule }.to change(CensorRule, :count).by(1)
        censor_rule = CensorRule.last
        expect(censor_rule.text).to eq(censor_rule_params[:text])
        expect(censor_rule.last_edit_editor).to eq('joe_admin')
        expect(censor_rule.censorable).to be_nil
        expect(censor_rule.colour).to eq('black')
      end

      it 'creates a blue rule when blue is selected' do
        post admin_censor_rules_path,
             params: { censor_rule: censor_rule_params.merge(colour: 'blue') }
        expect(CensorRule.last.colour).to eq('blue')
      end

      context 'successfully saving the censor rule' do
        it 'redirects to the censor rules index' do
          create_censor_rule
          expect(response).to redirect_to(admin_censor_rules_path)
          msg = 'Censor rule was successfully created.'
          expect(flash[:notice]).to eq(msg)
        end
      end

      context 'unsuccessfully saving the censor rule' do
        before do
          allow_any_instance_of(CensorRule).to receive(:save).and_return(false)
        end

        it 'does not persist the censor rule' do
          expect { create_censor_rule }.not_to change(CensorRule, :count)
          expect(response).to have_http_status(:unprocessable_content)
        end

        it 'shows the form again, posting to the global rules' do
          create_censor_rule
          expect(response).to have_http_status(:unprocessable_content)
          expect(page.at_css('h1').text).to eq('New censor rule')
          expect(new_rule_form['action']).to eq(admin_censor_rules_path)
          expect(applies_to_everything?).to be(true)
        end
      end
    end

    subjects.each do |param, kind|
      context "#{param} param" do
        let(:censor_rule_params) do
          params = FactoryBot.attributes_for(kind[:rule_factory])
          # last_edit_editor gets set in the controller
          params.delete(:last_edit_editor)
          params
        end

        let!(:censorable) { FactoryBot.create(kind[:factory]) }
        let(:rules_path) { send(kind[:rules_path], censorable) }
        let(:admin_path) { send(kind[:admin_path], censorable) }

        def create_censor_rule
          post rules_path, params: { censor_rule: censor_rule_params }
        end

        it 'creates a rule for the record, edited by the current admin' do
          expect { create_censor_rule }.to change(CensorRule, :count).by(1)
          censor_rule = CensorRule.last
          expect(censor_rule.text).to eq(censor_rule_params[:text])
          expect(censor_rule.last_edit_editor).to eq('joe_admin')
          expect(censor_rule.censorable).to eq(censorable)
        end

        context 'successfully saving the censor rule' do
          it 'confirms the rule is created and redirects to the record' do
            create_censor_rule
            msg = 'Censor rule was successfully created.'
            expect(flash[:notice]).to eq(msg)
            expect(response).to redirect_to(admin_path)
          end
        end

        context 'unsuccessfully saving the censor rule' do
          before do
            allow_any_instance_of(CensorRule).
              to receive(:save).and_return(false)
          end

          it 'does not persist the censor rule' do
            expect { create_censor_rule }.not_to change(CensorRule, :count)
            expect(response).to have_http_status(:unprocessable_content)
          end

          it 'shows the form again, posting to the rules for the record' do
            create_censor_rule
            expect(response).to have_http_status(:unprocessable_content)
            expect(page.at_css('h1').text).to eq('New censor rule')
            expect(new_rule_form['action']).to eq(rules_path)
            expect(applies_to_links).to include(admin_path)
          end
        end
      end
    end
  end

  describe 'GET edit' do
    rules.each do |description, (rule_factory, _admin_path)|
      context description do
        let(:censor_rule) { FactoryBot.create(rule_factory) }

        it 'shows the edit form for the rule' do
          get edit_admin_censor_rule_path(censor_rule)
          expect(response).to be_successful
          expect(page.at_css('h1').text).to eq('Edit censor rule')
          form = edit_form_for(censor_rule)
          expect(form).to be_present
          expect(form.at_css('#censor_rule_text')['value']).
            to eq('some text to redact')
        end
      end
    end
  end

  describe 'PUT update' do
    def update_censor_rule(censor_rule)
      put admin_censor_rule_path(censor_rule),
          params: { censor_rule: { text: 'different text' } }
    end

    rules.each do |description, (rule_factory, admin_path)|
      context description do
        let(:censor_rule) { FactoryBot.create(rule_factory) }

        context 'successfully saving the censor rule' do
          before { update_censor_rule(censor_rule) }

          it 'updates the rule, recording the current admin as editor' do
            censor_rule.reload
            expect(censor_rule.text).to eq('different text')
            expect(censor_rule.last_edit_editor).to eq('joe_admin')
          end

          it 'confirms the rule is updated and redirects to its subject' do
            msg = 'Censor rule was successfully updated.'
            expect(flash[:notice]).to eq(msg)
            expect(response).
              to redirect_to(subject_page(censor_rule, admin_path))
          end
        end

        context 'unsuccessfully saving the censor rule' do
          before do
            allow_any_instance_of(CensorRule).
              to receive(:save).and_return(false)
            update_censor_rule(censor_rule)
          end

          it 'does not update the censor rule' do
            expect(response).to have_http_status(:unprocessable_content)
            expect(censor_rule.reload.text).to eq('some text to redact')
          end

          it 'shows the edit form again' do
            expect(response).to have_http_status(:unprocessable_content)
            expect(page.at_css('h1').text).to eq('Edit censor rule')
            expect(edit_form_for(censor_rule)).to be_present
          end
        end
      end
    end
  end

  describe 'DELETE destroy' do
    rules.each do |description, (rule_factory, admin_path)|
      context description do
        let!(:censor_rule) { FactoryBot.create(rule_factory) }
        let!(:other_rule) { FactoryBot.create(rule_factory) }

        before { delete admin_censor_rule_path(censor_rule) }

        it 'destroys the given censor rule and no other' do
          expect(CensorRule).not_to exist(censor_rule.id)
          expect(CensorRule).to exist(other_rule.id)
        end

        it 'confirms the rule is destroyed and redirects to its subject' do
          msg = 'Censor rule was successfully destroyed.'
          expect(flash[:notice]).to eq(msg)
          expect(response).
            to redirect_to(subject_page(censor_rule, admin_path))
        end
      end
    end
  end
end
