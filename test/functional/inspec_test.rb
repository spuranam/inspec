# encoding: utf-8
# author: Dominik Richter
# author: Christoph Hartmann

require 'functional/helper'

describe 'command tests' do
  include FunctionalHelper

  describe 'detect' do
    it 'runs well on all nodes' do
      out = inspec('detect')
      out.stderr.must_equal ''
      out.exit_status.must_equal 0
      j = JSON.load(out.stdout)
      j.keys.must_include 'name'
      j.keys.must_include 'family'
      j.keys.must_include 'arch'
      j.keys.must_include 'release'
    end
  end

  describe 'version' do
    it 'provides the version number on stdout' do
      out = inspec('version')
      out.stderr.must_equal ''
      out.exit_status.must_equal 0
      out.stdout.must_equal Inspec::VERSION+"\n"
    end
  end

  describe 'shell' do
    it 'provides a help command' do
      out = CMD.run_command("echo \"help\nexit\" | #{exec_inspec} shell")
      out.exit_status.must_equal 0
      out.stdout.must_include 'Available commands:'
      out.stdout.must_include 'You are currently running on:'
    end

    it 'exposes all resources' do
      out = CMD.run_command("echo \"os\nexit\" | #{exec_inspec} shell")
      out.exit_status.must_equal 0
      out.stdout.must_match /^=> .*Operating.* .*System.* .*Detection.*$/
    end
  end

  describe 'check' do
    it 'verifies that a profile is ok' do
      out = inspec('check ' + example_profile)
      out.stdout.must_match /Valid.*true/
      out.exit_status.must_equal 0
    end
  end
end
