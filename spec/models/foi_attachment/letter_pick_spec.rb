require 'spec_helper'

RSpec.describe FoiAttachment::LetterPick do
  let(:letter) {
    ("Dear Ms Example\nThank you for your request for " \
    "information dated 3 May, our reference FOI 123. " * 3) +
      "Yours sincerely"
  }

  it 'prefers the response letter over a survey and an annex' do
    documents = [[
      'FOI Satisfaction Questionnaire.docx',
      'Dear customer, please tell us about your request. ' * 5
    ], ['Annex A data.pdf', 'Ward  Count  2021  2022 ' * 20],
                 ['FOI 8650 Response.pdf', letter]]
    expect(described_class.pick(documents)).to eq('FOI 8650 Response.pdf')
  end

  it 'finds a question-and-answer response that has no letter wording' do
    documents = [['10234513 Response.pdf', 'Request: how many staff? ' \
                                           'Response: 14. Request: what ' \
                                           'budget? Response: £30,000. ' * 3]]
    expect(described_class.pick(documents)).to eq('10234513 Response.pdf')
  end

  it 'picks nothing from leaflets and spreadsheets' do
    documents = [[
      'Your rights summary.pdf',
      'What rights do I have under the Act? ' * 10
    ], ['spend.xlsx', 'a b c ' * 50]]
    expect(described_class.pick(documents)).to be_nil
  end
end
