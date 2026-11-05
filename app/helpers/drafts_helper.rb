module DraftsHelper
  def attachment_mb(bytes)
    "#{number_with_precision(bytes.to_f / 1.megabyte, precision: 1, strip_insignificant_zeros: true)} MB"
  end
end
