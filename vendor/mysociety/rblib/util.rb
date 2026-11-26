# -*- encoding : utf-8 -*-
# util.rb:
# mySociety library of general utility functions
#
# Copyright (c) 2010 UK Citizens Online Democracy. All rights reserved.
# Email: louise@mysociety.org; WWW: http://www.mysociety.org/
#
#
require 'openssl'
require 'securerandom'
module MySociety

  module Util
    # Makes a random token, suitable for using in URLs e.g confirmation messages.
    def self.generate_token
      SecureRandom.alphanumeric(19)
    end

  end

end
