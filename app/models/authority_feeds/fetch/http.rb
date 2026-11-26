require 'net/http'

module AuthorityFeeds
  module Fetch
    # Rate-limited HTTP client for regulator feeds: short timeouts, capped body
    # size, no cookies, and no email address in User-Agent.
    class Http
      class Failed < StandardError; end

      AGENT = "#{AlaveteliConfiguration.site_name} " \
              'decision check (once a day)'.freeze
      # Bounds response size against runaway/faulty upstream replies.
      MAX_BYTES = 5.megabytes
      # Seconds between requests to one site (the ICO's robots.txt asks for 6).
      # Specs set 0.
      cattr_accessor :pause, default: 10

      def get(url)
        perform(URI(url)) { |uri| Net::HTTP::Get.new(uri) }
      end

      def post_json(url, data)
        perform(URI(url)) do |uri|
          Net::HTTP::Post.new(uri).tap do |request|
            request['Content-Type'] = 'application/json'
            request.body = data.to_json
          end
        end
      end

      private

      def perform(uri)
        wait
        request = yield(uri)
        request['User-Agent'] = AGENT
        request['Accept'] = '*/*'
        body = +''
        response = Net::HTTP.start(uri.host, uri.port,
                                   use_ssl: uri.scheme == 'https',
                                   open_timeout: 15,
                                   read_timeout: 30) do |http|
          http.request(request) do |answer|
            answer.read_body do |chunk|
              body << chunk
              if body.bytesize > MAX_BYTES
                raise Failed,
                      "#{uri.host} sent more than #{MAX_BYTES / 1.megabyte} MB"
              end
            end
          end
        end
        @last = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        unless response.is_a?(Net::HTTPSuccess)
          raise Failed, "#{uri.host} answered #{response.code}"
        end

        body.force_encoding(Encoding::UTF_8)
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError,
             OpenSSL::SSL::SSLError => e
        raise Failed, "#{uri.host}: #{e.class.name.demodulize}"
      end

      def wait
        return unless @last && pause.positive?

        left = pause - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last)
        sleep(left) if left.positive?
      end
    end
  end
end
