module DraftsHelper
  def draft_api_labels(draft)
    [ [ "Drafted", draft.created_via_token ], [ "Edited", draft.last_edited_via_token ] ].filter_map do |verb, token|
      "#{verb} via API (#{token.name})" if token
    end
  end

  def attachment_mb(bytes)
    "#{number_with_precision(bytes.to_f / 1.megabyte, precision: 1, strip_insignificant_zeros: true)} MB"
  end
end
