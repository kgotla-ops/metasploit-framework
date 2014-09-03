
require 'metasploit/framework/login_scanner/http'

##
#
# The Metasploit::Framework::LoginScanner::Glassfish class provides methods to do login routines
# for Glassfish 2, 3 and 4.
#
##

module Metasploit
  module Framework
    module LoginScanner

      # I don't want to raise RuntimeError to be able to abort login
      class GlassfishError < StandardError
      end

      class Glassfish < HTTP

        DEFAULT_PORT  = 4848
        PRIVATE_TYPES = [ :password ]

        # Set the Glassfish version
        attr_accessor :version

        # Session ID needs to be actively tracked
        attr_accessor :jsession


        #
        # Sends a HTTP request with Rex
        #
        # @param opts [Hash] The HTTP request options. See #request_raw in client.rb
        # @return [Rex::Proto::Http::Response] The HTTP response
        #
        def send_request(opts)
          cli = Rex::Proto::Http::Client.new(host, port, {}, ssl, ssl_version)
          cli.connect
          req = cli.request_raw(opts)
          res = cli.send_recv(req)

          # Found a cookie? Set it. We're going to need it.
          if res && res.get_cookies =~ /JSESSIONID=(\w*);/i
            self.jsession = $1
          end

          res
        end


        #
        # As of Sep 2014, if Secure Admin is disabled, it simply means the admin isn't allowed
        # to login remotely. However, the authentication will still run and hint whether the
        # password is correct or not.
        #
        # @param res [Rex::Proto::Http::Response] The HTTP auth response
        # @return [boolean] True if disabled, otherwise false
        #
        def is_secure_admin_disabled?(res)
          return (res.body =~ /Secure Admin must be enabled/i) ? true : false
        end


        #
        # Sends a login request
        #
        # @param credential [Metasploit::Framework::Credential] The credential object
        # @return [Rex::Proto::Http::Response] The HTTP auth response
        #
        def try_login(credential)
          data  = "j_username=#{Rex::Text.uri_encode(credential.public)}&"
          data << "j_password=#{Rex::Text.uri_encode(credential.private)}&"
          data << 'loginButton=Login'

          opts = {
            'uri'     => '/j_security_check',
            'method'  => 'POST',
            'data'    => data,
            'headers' => {
              'Content-Type'   => 'application/x-www-form-urlencoded',
              'Cookie'         => "JSESSIONID=#{self.jsession}",
            }
          }

          send_request(opts)
        end


        #
        # Tries to login to Glassfish version 2
        #
        # @param credential [Metasploit::Framework::Credential] The credential object
        # @return [Hash] A hash with :status being a Metasploit::Model::Login::Status, and :proof that contains the HTTP response body
        #
        def try_glassfish_2(credential)
          res = try_login(credential)
          if res and res.code == 302
            opts = {
              'uri'     => '/applications/upload.jsf',
              'method'  => 'GET',
              'headers' => {
                'Cookie'  => "JSESSIONID=#{self.jsession}"
              }
            }
            res = send_request(opts)
            p = /<title>Deploy Enterprise Applications\/Modules/
            if (res && res.code.to_i == 200 && res.body.match(p) != nil)
              return {:status => Metasploit::Model::Login::Status::SUCCESSFUL, :proof => res.body}
            end
          end

          {:status => Metasploit::Model::Login::Status::INCORRECT, :proof => res.body}
        end


        #
        # Tries to login to Glassfish version 3 or 4 (as of now it's the latest)
        #
        # @param credential [Metasploit::Framework::Credential] The credential object
        # @return [Hash] A hash with :status being a Metasploit::Model::Login::Status, and :proof that contains the HTTP response body
        #
        def try_glassfish_3(credential)
          res = try_login(credential)
          if res and res.code == 302
            opts = {
              'uri'     => '/common/applications/uploadFrame.jsf',
              'method'  => 'GET',
              'headers' => {
                'Cookie'  => "JSESSIONID=#{self.jsession}"
              }
            }
            res = send_request(opts)

            p = /<title>Deploy Applications or Modules/
            if (res && res.code.to_i == 200 && res.body.match(p) != nil)
              return {:status => Metasploit::Model::Login::Status::SUCCESSFUL, :proof => res.body}
            end
          elsif res && is_secure_admin_disabled?(res)
            return {:status => Metasploit::Model::Login::Status::SUCCESSFUL, :proof => res.body}
          elsif res && res.code == 400
            raise GlassfishError, "400: Bad HTTP request from try_login"
          end

          {:status => Metasploit::Model::Login::Status::INCORRECT, :proof => res.body}
        end


        #
        # Decides which login routine and returns the results
        #
        # @param credential [Metasploit::Framework::Credential] The credential object
        # @return [Result]
        #
        def attempt_login(credential)
          result_opts = { credential: credential }

          begin
            case self.version
            when /^[29]\.x$/
              status = try_glassfish_2(credential)
              result_opts.merge!(status: status[:status], proof:status[:proof])
            when /^[34]\./
              status = try_glassfish_3(credential)
              result_opts.merge!(status: status[:status], proof:status[:proof])
           else
              raise GlassfishError, "Glassfish version '#{self.version}' not supported"
            end
          rescue ::EOFError, Rex::ConnectionError, ::Timeout::Error
            result_opts.merge!(status: Metasploit::Model::Login::Status::UNABLE_TO_CONNECT)
          end

          Result.new(result_opts)
        end

      end
    end
  end
end

