module Fastlane
  module Actions
    require_relative 'upload_to_qawolf_action'
    class QawolfAction < UploadToQawolfAction
      #####################################################
      # @!group Documentation
      #####################################################

      def self.description
        "Alias for the `upload_to_qawolf` action"
      end
    end
  end
end
