# Administrative management of Disclosures::Document records.
class Admin::Disclosures::DocumentsController < Admin::Disclosures::BaseController
  include ::Disclosures::DocumentManagement

  before_action :find_document
  before_action { require_ability(:admin) }
  read_only except: %i[manage edit]

  def publish
    require_ability(:publish_document)
    ::Disclosures::Publication.new(@document, user: current_user).publish!
    redirect_with(disclosure_manage_document_path(@document),
                  notice: 'Published for the requester. It is now public.')
  rescue ::Disclosures::Error => e
    redirect_with(disclosure_manage_document_path(@document), error: e.message)
  end

  def erase
    require_ability(:erase_document)
    unless params[:confirm] == '1'
      return redirect_with(
        disclosure_manage_document_path(@document),
        error: 'Tick that you want to erase every file of this document.'
      )
    end

    ::Disclosures::Publication.new(@document, user: current_user).erase!
    redirect_with(disclosure_manage_document_path(@document),
                  notice: 'Erased. Only a record of the document is left.')
  end
end
