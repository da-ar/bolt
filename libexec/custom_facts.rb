#! /opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

require 'json'
require 'puppet'
require 'puppet/module_tool/tar'
require 'puppet/util/network_device'
require 'tempfile'

args = JSON.parse(STDIN.read)

Dir.mktmpdir do |puppet_root|
  # Create temporary directories for all core Puppet settings so we don't clobber
  # existing state or read from puppet.conf. Also create a temporary modulepath.
  moduledir = File.join(puppet_root, 'modules')
  Dir.mkdir(moduledir)
  cli = Puppet::Settings::REQUIRED_APP_SETTINGS.flat_map do |setting|
    ["--#{setting}", File.join(puppet_root, setting.to_s.chomp('dir'))]
  end
  cli << '--modulepath' << moduledir
  Puppet.initialize_settings(cli)

  Tempfile.open('plugins.tar.gz') do |plugins|
    File.binwrite(plugins, Base64.decode64(args['plugins']))
    Puppet::ModuleTool::Tar.instance.unpack(plugins, moduledir, Etc.getlogin || Etc.getpwuid.name)
  end

  env = Puppet.lookup(:environments).get('production')
  env.each_plugin_directory do |dir|
    $LOAD_PATH << dir unless $LOAD_PATH.include?(dir)
  end

  if (conn_info = args['_target'])

    unless conn_info['type']
      puts "Cannot collect facts for a remote target without knowing it's type."
      exit 1
    end
    # Some valid bolt urls like file:///tmp/foo don't have a host which means we don't have a name
    unless conn_info['host']
      puts "Cannot collect facts for a remote target with a host in it's name"
    end

    # TODO: validate_target
    special_keys = %w[type debug uri]
    connection = conn_info.reject { |k, _| special_keys.include?(k) }
    device = OpenStruct.new(connection)
    device.url = conn_info['uri']
    device.provider = conn_info['type']
    device.options = { debug: true } if conn_info['debug']
    Puppet[:facts_terminus] = :network_device
    Puppet[:certname] = device.name
    Puppet::Util::NetworkDevice.init(device)
  end

  facts = Puppet::Node::Facts.indirection.find(SecureRandom.uuid, environment: env)

  # CODEREVIEW: the device command does this should we?
  facts.name = facts.values['clientcert']
  puts(facts.values.to_json)
end

exit 0
