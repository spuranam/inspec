# encoding: utf-8
# copyright: 2015, Vulcano Security GmbH
# author: Christoph Hartmann
# author: Dominik Richter
# license: All rights reserved

# The file format consists of
# - username
# - password
# - userid
# - groupid
# - user id info
# - home directory
# - command

require 'utils/parser'

module Inspec::Resources
  class Passwd < Inspec.resource(1) # rubocop:disable Metrics/ClassLength
    name 'passwd'
    desc 'Use the passwd InSpec audit resource to test the contents of /etc/passwd, which contains the following information for users that may log into the system and/or as users that own running processes.'
    example "
      describe passwd do
        its('users') { should_not include 'forbidden_user' }
      end

      describe passwd.uids(0) do
        its('users') { should cmp 'root' }
        its('count') { should eq 1 }
      end

      describe passwd.shells(/nologin/) do
        # find all users with a nologin shell
        its('users') { should_not include 'my_login_user' }
      end
    "

    include PasswdParser

    attr_reader :uid
    attr_reader :params
    attr_reader :content
    attr_reader :lines

    def initialize(path = nil, opts = nil)
      opts ||= {}
      @path = path || '/etc/passwd'
      @content = opts[:content] || inspec.file(@path).content
      @lines = @content.to_s.split("\n")
      @filters = opts[:filters] || ''
      @params = parse_passwd(@content)
    end

    def filter(hm = {})
      return self if hm.nil? || hm.empty?
      res = @params
      filters = ''
      hm.each do |attr, condition|
        res, filters = filter_attribute(attr, condition, res, filters)
      end
      content = res.map { |x| x.values.join(':') }.join("\n")
      Passwd.new(@path, content: content, filters: @filters + filters)
    end

    def usernames
      warn '[DEPRECATION] `passwd.usernames` is deprecated. Please use `passwd.users` instead. It will be removed in version 1.0.0.'
      users
    end

    def username
      warn '[DEPRECATION] `passwd.user` is deprecated. Please use `passwd.users` instead. It will be removed in version 1.0.0.'
      users[0]
    end

    def uid(x)
      warn '[DEPRECATION] `passwd.uid(arg)` is deprecated. Please use `passwd.uids(arg)` instead. It will be removed in version 1.0.0.'
      uids(x)
    end

    def users(name = nil)
      name.nil? ? map_data('user') : filter(user: name)
    end

    def passwords(password = nil)
      password.nil? ? map_data('password') : filter(password: password)
    end

    def uids(uid = nil)
      uid.nil? ? map_data('uid') : filter(uid: uid)
    end

    def gids(gid = nil)
      gid.nil? ? map_data('gid') : filter(gid: gid)
    end

    def homes(home = nil)
      home.nil? ? map_data('home') : filter(home: home)
    end

    def shells(shell = nil)
      shell.nil? ? map_data('shell') : filter(shell: shell)
    end

    def to_s
      f = @filters.empty? ? '' : ' with'+@filters
      "/etc/passwd#{f}"
    end

    def count
      @params.length
    end

    private

    def map_data(id)
      @params.map { |x| x[id] }
    end

    def filter_res_line(item, matcher, condition, positive)
      # TODO: REWORK ALL OF THESE, please don't depend on them except for simple equality!
      case matcher
      when '<'
        item.to_i < condition
      when '<='
        item.to_i <= condition
      when '>'
        item.to_i > condition
      when '>='
        item.to_i >= condition
      else
        condition = condition.to_s if condition.is_a? Integer
        case item
        when condition
          positive
        else
          !positive
        end
      end
    end

    def filter_attribute(attr, condition, res, filters)
      matcher = '=='
      positive = true
      if condition.is_a?(Hash) && condition.length == 1
        matcher = condition.keys[0].to_s
        condition = condition.values[0]
      end
      positive = false if matcher == '!='

      a = res.find_all do |line|
        filter_res_line(line[attr.to_s], matcher, condition, positive)
      end
      b = filters + " #{attr} #{matcher} #{condition.inspect}"
      [a, b]
    end
  end
end
