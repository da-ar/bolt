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

    require 'puppet/resource_api/transport'

    # Transport.connect will modify this hash!
    transport_conn_info =  conn_info.each_with_object({}) {|(k,v), h| h[k.to_sym] = v }

    transport = Puppet::ResourceApi::Transport.connect(conn_info['type'], transport_conn_info)
    transport_wrapper = Puppet::ResourceApi::Transport::Wrapper.new(conn_info['type'], transport)
    if  Puppet::Util::NetworkDevice.respond_to?(:set_transport)
      Puppet::Util::NetworkDevice.set_transport(conn_info['type'], transport_wrapper)
    else
      Puppet::Util::NetworkDevice.instance_variable_set(:@current, transport_wrapper)
    end

    Puppet[:facts_terminus] = :network_device
    Puppet[:certname] = conn_info['uri']
  end


  facts = Puppet::Node::Facts.indirection.find(SecureRandom.uuid, environment: env)

  # CODEREVIEW: the device command does this should we?
  facts.name = facts.values['clientcert']
  puts(facts.values.to_json)
end

exit 0
