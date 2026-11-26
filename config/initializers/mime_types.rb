# Be sure to restart your server when you modify this file.

# Add new mime types for use in respond_to blocks:
# Mime::Type.register "text/richtext", :rtf

Mime::Type.register 'message/rfc822', :eml

# Propshaft serves an asset with the type Rails gives its extension.
Mime::Type.register 'image/x-icon', :ico
