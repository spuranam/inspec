# encoding: utf-8
# author: Christoph Hartmann
# author: Dominik Richter

require 'thor'
require 'erb'

module Compliance
  class ComplianceCLI < Inspec::BaseCLI # rubocop:disable Metrics/ClassLength
    namespace 'compliance'

    desc 'login SERVER', 'Log in to a Chef Compliance SERVER'
    option :server, type: :string, desc: 'Chef Compliance Server URL'
    option :insecure, aliases: :k, type: :boolean,
      desc: 'Explicitly allows InSpec to perform "insecure" SSL connections and transfers'
    option :user, type: :string, required: false,
      desc: 'Chef Compliance Username (for legacy auth)'
    option :password, type: :string, required: false,
      desc: 'Chef Compliance Password (for legacy auth)'
    option :apipath, type: :string, default: '/api',
      desc: 'Set the path to the API, defaults to /api'
    option :token, type: :string, required: false,
      desc: 'Chef Compliance access token'
    option :refresh_token, type: :string, required: false,
      desc: 'Chef Compliance refresh token'
    def login(server) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/AbcSize, PerceivedComplexity
      # show warning if the Compliance Server does not support
      if !Compliance::Configuration.new.supported?(:oidc) && (!options['token'].nil? || !options['refresh_token'].nil?)
        puts 'Your server supports --user and --password only'
      end

      options['server'] = server
      url = options['server'] + options['apipath']
      if !options['user'].nil? && !options['password'].nil?
        # username / password
        success, msg = login_legacy(url, options['user'], options['password'], options['insecure'])
      elsif !options['user'].nil? && !options['token'].nil?
        # access token
        success, msg = store_access_token(url, options['user'], options['token'], options['insecure'])
      elsif !options['refresh_token'].nil? && !options['user'].nil?
        # refresh token
        success, msg = store_refresh_token(url, options['refresh_token'], true, options['user'], options['insecure'])
        # TODO: we should login with the refreshtoken here
      elsif !options['refresh_token'].nil?
        success, msg = login_refreshtoken(url, options)
      else
        puts 'Please run `inspec compliance login` with options --token or --refresh_token and --user'
        exit 1
      end

      if success
        puts 'Successfully authenticated'
      else
        puts msg
      end
    end

    desc 'profiles', 'list all available profiles in Chef Compliance'
    def profiles
      config = Compliance::Configuration.new
      profiles = Compliance::API.profiles(config)
      if !profiles.empty?
        # iterate over profiles
        headline('Available profiles:')
        profiles.each { |profile|
          li("#{profile[:org]}/#{profile[:name]}")
        }
      else
        puts 'Could not find any profiles'
      end
    end

    desc 'exec PROFILE', 'executes a Chef Compliance profile'
    exec_options
    def exec(*tests)
      # iterate over tests and add compliance scheme
      tests = tests.map { |t| 'compliance://' + t }

      # execute profile from inspec exec implementation
      diagnose
      run_tests(tests, opts)
    end

    desc 'upload PATH', 'uploads a local profile to Chef Compliance'
    option :overwrite, type: :boolean, default: false,
      desc: 'Overwrite existing profile on Chef Compliance.'
    def upload(path) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, PerceivedComplexity
      unless File.exist?(path)
        puts "Directory #{path} does not exist."
        exit 1
      end

      o = options.dup
      configure_logger(o)
      # check the profile, we only allow to upload valid profiles
      profile = Inspec::Profile.for_target(path, o)

      # start verification process
      error_count = 0
      error = lambda { |msg|
        error_count += 1
        puts msg
      }

      result = profile.check
      unless result[:summary][:valid]
        error.call('Profile check failed. Please fix the profile before upload.')
      else
        puts('Profile is valid')
      end

      # determine user information
      config = Compliance::Configuration.new
      if config['token'].nil? || config['user'].nil?
        error.call('Please login via `inspec compliance login`')
      end

      # owner
      owner = config['user']
      # read profile name from inspec.yml
      profile_name = profile.params[:name]

      # check that the profile is not uploaded already,
      # confirm upload to the user (overwrite with --force)
      if Compliance::API.exist?(config, "#{owner}/#{profile_name}") && !options['overwrite']
        error.call('Profile exists on the server, use --overwrite')
      end

      # abort if we found an error
      if error_count > 0
        puts "Found #{error_count} error(s)"
        exit 1
      end

      # if it is a directory, tar it to tmp directory
      if File.directory?(path)
        archive_path = Dir::Tmpname.create([profile_name, '.tar.gz']) {}
        # archive_path = file.path
        puts "Generate temporary profile archive at #{archive_path}"
        profile.archive({ output: archive_path, ignore_errors: false, overwrite: true })
      else
        archive_path = path
      end

      puts "Start upload to #{owner}/#{profile_name}"
      pname = ERB::Util.url_encode(profile_name)

      puts 'Uploading to Chef Compliance'
      success, msg = Compliance::API.upload(config, owner, pname, archive_path)

      if success
        puts 'Successfully uploaded profile'
      else
        puts 'Error during profile upload:'
        puts msg
      end
    end

    desc 'version', 'displays the version of the Chef Compliance server'
    def version
      config = Compliance::Configuration.new
      info = Compliance::API.version(config['server'], config['insecure'])
      if !info.nil? && info['version']
        puts "Chef Compliance version: #{info['version']}"
      else
        puts 'Could not determine server version.'
      end
    end

    desc 'logout', 'user logout from Chef Compliance'
    def logout
      config = Compliance::Configuration.new
      unless config.supported?(:oidc) || config['token'].nil?
        config = Compliance::Configuration.new
        url = "#{config['server']}/logout"
        Compliance::API.post(url, config['token'], config['insecure'], !config.supported?(:oidc))
      end

      success = config.destroy

      if success
        puts 'Successfully logged out'
      else
        puts 'Could not log out'
      end
    end

    private

    def login_refreshtoken(url, options)
      success, msg, access_token = Compliance::API.post_refresh_token(url, options['refresh_token'], options['insecure'])
      if success
        config = Compliance::Configuration.new
        config['server'] = url
        config['token'] = access_token
        config['insecure'] = options['insecure']
        config['version'] = Compliance::API.version(url, options['insecure'])
        config.store
      end

      [success, msg]
    end

    def login_legacy(url, username, password, insecure)
      config = Compliance::Configuration.new
      success, data = Compliance::API.legacy_login_post(url+'/oauth/token', username, password, insecure)
      if !data.nil?
        tokendata = JSON.parse(data)
        if tokendata['access_token']
          config['server'] = url
          config['user'] = username
          config['token'] = tokendata['access_token']
          config['insecure'] = insecure
          config['version'] = Compliance::API.version(url, insecure)
          config.store
          success = true
          msg = 'Successfully authenticated'
        else
          msg = 'Reponse does not include a token'
        end
      else
        msg = "Authentication failed for Server: #{url}"
      end
      [success, msg]
    end

    # saves a user access token (limited time)
    def store_access_token(url, user, token, insecure)
      config = Compliance::Configuration.new
      config['server'] = url
      config['insecure'] = insecure
      config['user'] = user
      config['token'] = token
      config['version'] = Compliance::API.version(url, insecure)
      config.store

      [true, 'access token stored']
    end

    # saves the a user refresh token supplied by the user
    def store_refresh_token(url, refresh_token, verify, user, insecure)
      config = Compliance::Configuration.new
      config['server'] = url
      config['refresh_token'] = refresh_token
      config['user'] = user
      config['insecure'] = insecure
      config['version'] = Compliance::API.version(url, insecure)

      if !verify
        config.store
        success = true
        msg = 'refresh token stored'
      else
        success, msg, access_token = Compliance::API.post_refresh_token(url, refresh_token, insecure)
        if success
          config['token'] = access_token
          config.store
          msg = 'token verified and stored'
        end
      end

      [success, msg]
    end
  end

  # register the subcommand to Inspec CLI registry
  Inspec::Plugins::CLI.add_subcommand(ComplianceCLI, 'compliance', 'compliance SUBCOMMAND ...', 'Chef Compliance commands', {})
end
