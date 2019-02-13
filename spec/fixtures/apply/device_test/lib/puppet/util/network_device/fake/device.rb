# frozen_string_literal: true

require 'puppet/util/network_device/base'

module Puppet::Util::NetworkDevice::Fake # rubocop:disable Style/ClassAndModuleChildren
  class Device
    def initialize(url, _options = nil)
      @path = URI.parse(url).path
    end

    def data
      if File.file? @path
        JSON.parse(File.read(@path))
      else
        {}
      end
    end

    def write(new_data)
      File.write(@path, new_data.to_json)
    end

    def facts
      {
        'operatingsystem' => 'FakeDevice',
        'exists' => File.exist?(@path),
        'size' => File.size?(@path) || 0
      }
    end

    def get
      data.map do |k, v|
        {
          name: k,
          content: v,
          ensure: 'present'
        }
      end
    end

    def set(path, val, _merge = false)
      new = data
      new[path] = val
      write(new)
    end

    def delete(path)
      new = data
      new.delete(path)
      write(new)
    end
  end
end
