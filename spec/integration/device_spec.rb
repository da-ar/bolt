# frozen_string_literal: true

require 'spec_helper'
require 'bolt_spec/conn'
require 'bolt_spec/files'
require 'bolt_spec/integration'
require 'bolt_spec/puppet_agent'
require 'bolt_spec/run'

describe "devices" do
  include BoltSpec::Conn
  include BoltSpec::Files
  include BoltSpec::Integration
  include BoltSpec::PuppetAgent
  include BoltSpec::Run

  let(:modulepath) { File.join(__dir__, '../fixtures/apply') }
  let(:config_flags) { %W[--format json --nodes #{uri} --password #{password} --modulepath #{modulepath}] + tflags }

  describe 'over ssh', ssh: true do
    let(:uri) { conn_uri('ssh') }
    let(:password) { conn_info('ssh')[:password] }
    let(:tflags) { %W[--no-host-key-check --run-as root --sudo-password #{password}] }

    let(:device_url) { "file:///tmp/#{SecureRandom.uuid}.json" }

    def root_config
      { 'modulepath' => File.join(__dir__, '../fixtures/apply'),
        'ssh' => {
          'run-as' => 'root',
          'sudo-password' => conn_info('ssh')[:password],
          'host-key-check' => false
        } }
    end

    def agent_version_inventory
      { 'groups' => [
        { 'name' => 'agent_targets',
          'groups' => [
            { 'name' => 'puppet_6',
              'nodes' => [conn_uri('ssh', override_port: 20024)],
              'config' => { 'ssh' => { 'port' => 20024 } } }
          ],
          'config' => {
            'ssh' => { 'host' => conn_info('ssh')[:host],
                       'host-key-check' => false,
                       'user' => conn_info('ssh')[:user],
                       'password' => conn_info('ssh')[:password],
                       'key' => conn_info('ssh')[:key] }
          } }
      ] }
    end

    let(:device_inventory) do
      device_group = { 'name' => 'device_targets',
                       'nodes' => [
                         { 'name' => device_url,
                           'config' => {
                             'transport' => 'remote',
                             'remote' => {
                               'type' => 'fake',
                               'run-on' => 'puppet_6'
                             }
                           } }
                       ] }
      inv = agent_version_inventory
      inv['groups'] << device_group
      inv
    end

    after(:all) do
      uninstall('puppet_6', inventory: agent_version_inventory)
    end

    context "when running against puppet 6" do
      before(:all) do
        install('puppet_6', inventory: agent_version_inventory)
      end

      it 'runs a plan that collects facts' do
        with_tempfile_containing('inventory', YAML.dump(device_inventory), '.yaml') do |inv|
          results = run_cli_json(%W[plan run device_test::facts --nodes device_targets
                                    --modulepath #{modulepath} --inventoryfile #{inv.path}])
          expect(results).not_to include("kind")
          name, facts = results.first
          expect(name).to eq(device_url)
          expect(facts).to include("operatingsystem" => "FakeDevice",
                                   "exists" => false,
                                   "clientcert" => device_url)
        end
      end

      it 'runs a plan that applies resources' do
        with_tempfile_containing('inventory', YAML.dump(device_inventory), '.yaml') do |inv|
          results = run_cli_json(%W[plan run device_test::set_a_val
                                    --nodes device_targets
                                    --modulepath #{modulepath} --inventoryfile #{inv.path}])
          expect(results).not_to include("kind")

          report = results[0]['result']['report']
          expect(report['resource_statuses']).to include("Fake_device[key1]")

          file_path = URI(device_url).path
          content = run_command("cat '#{file_path}'", 'puppet_6', config: root_config,
                                                                  inventory: device_inventory)[0]['result']['stdout']
          expect(content).to eq({ key1: "val1" }.to_json)
        end
      end
    end
  end
end
