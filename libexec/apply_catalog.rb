#! /opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'puppet'
require 'puppet/configurer'
require 'puppet/module_tool/tar'
require 'puppet/util/network_device'
require 'securerandom'
require 'tempfile'

args = JSON.parse(ARGV[0] ? File.read(ARGV[0]) : STDIN.read)

# Create temporary directories for all core Puppet settings so we don't clobber
# existing state or read from puppet.conf. Also create a temporary modulepath.
# Additionally include rundir, which gets its own initialization.
puppet_root = Dir.mktmpdir
moduledir = File.join(puppet_root, 'modules')
Dir.mkdir(moduledir)
cli = (Puppet::Settings::REQUIRED_APP_SETTINGS + [:rundir]).flat_map do |setting|
  ["--#{setting}", File.join(puppet_root, setting.to_s.chomp('dir'))]
end
cli << '--modulepath' << moduledir
Puppet.initialize_settings(cli)

# Avoid extraneous output
Puppet[:report] = false

# Make sure to apply the catalog
Puppet[:noop] = args['_noop'] || false

Puppet[:default_file_terminus] = :file_server

exit_code = 0
begin
  # This happens implicitly when running the Configurer, but we make it explicit here. It creates the
  # directories we configured earlier.
  Puppet.settings.use(:main)

  Tempfile.open('plugins.tar.gz') do |plugins|
    File.binwrite(plugins, Base64.decode64(args['plugins']))
    Puppet::ModuleTool::Tar.instance.unpack(plugins, moduledir, Etc.getlogin || Etc.getpwuid.name)
  end

  env = Puppet.lookup(:environments).get('production')
  # Needed to ensure features are loaded
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
    Puppet::ResourceApi::Transport.inject_device(conn_info['type'], transport_wrapper)

    Puppet[:facts_terminus] = :network_device
    Puppet[:certname] = conn_info['uri']
  end

  # Ensure custom facts are available for provider suitability tests
  # TODO: skip this for devices?
  facts = Puppet::Node::Facts.indirection.find(SecureRandom.uuid, environment: env)

  report = if Puppet::Util::Package.versioncmp(Puppet.version, '5.0.0') > 0
             Puppet::Transaction::Report.new
           else
             Puppet::Transaction::Report.new('apply')
           end

  overrides = { current_environment: env,
                loaders: Puppet::Pops::Loaders.new(env) }
  overrides[:network_device] = true if args['_target']

  Puppet.override(overrides) do
    catalog = Puppet::Resource::Catalog.from_data_hash(args['catalog'])
    catalog.environment = env.name.to_s
    catalog.environment_instance = env
    if defined?(Puppet::Pops::Evaluator::DeferredResolver)
      # Only available in Puppet 6
      Puppet::Pops::Evaluator::DeferredResolver.resolve_and_replace(facts, catalog)
    end
    catalog = catalog.to_ral

    configurer = Puppet::Configurer.new
    configurer.run(catalog: catalog, report: report, pluginsync: false)
  end

  puts JSON.pretty_generate(report.to_data_hash)
  exit_code = report.exit_status != 1
ensure
  begin
    FileUtils.remove_dir(puppet_root)
  rescue Errno::ENOTEMPTY => e
    STDERR.puts("Could not cleanup temporary directory: #{e}")
  end
end

exit exit_code
