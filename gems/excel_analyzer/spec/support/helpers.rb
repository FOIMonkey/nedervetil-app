def fake_blob(io: nil, content_type:, service_name: 'raw_emails')
  dbl = double(io: io, content_type: content_type,
               service_name: service_name)
  allow(dbl).to receive(:open).and_yield(io)
  dbl
end
