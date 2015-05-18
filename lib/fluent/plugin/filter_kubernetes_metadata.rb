#
# Fluentd Kubernetes Metadata Filter Plugin - Enrich Fluentd events with
# Kubernetes metadata
#
# Copyright 2015 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
module Fluent
  class KubernetesMetadataFilter < Fluent::Filter
    Fluent::Plugin.register_filter('kubernetes_metadata', self)

    config_param :kubernetes_url, :string
    config_param :cache_size, :integer, default: 1000
    config_param :cache_ttl, :integer, default: 60 * 60
    config_param :watch, :bool, default: true
    config_param :apiVersion, :string, default: 'v1beta3'
    config_param :client_cert, :string, default: ''
    config_param :client_key, :string, default: ''
    config_param :ca_file, :string, default: ''
    config_param :verify_ssl, :bool, default: true
    config_param :container_name_to_kubernetes_name_regexp,
                 :string,
                 :default => '\/?[^_]+_(?<pod_container_name>[^\.]+)[^_]+_(?<pod_name>[^_]+)_(?<namespace>[^_]+)'
    config_param :bearer_token_file, :string, default: ''
    config_param :merge_json_log, :bool, default: true

    def get_metadata(pod_name, container_name, namespace)
      begin
        metadata = @client.get_pod(pod_name, namespace)
        if metadata
          return {
            uid:            metadata['metadata']['uid'],
            namespace:      metadata['metadata']['namespace'],
            pod_name:       metadata['metadata']['name'],
            container_name: container_name,
            labels:         metadata['metadata']['labels'].to_h,
            host:           metadata['spec']['host']
          }
        end
      rescue KubeException
        nil
      end
    end

    def initialize
      super
    end

    def configure(conf)
      super

      require 'kubeclient'
      require 'active_support/core_ext/object/blank'
      require 'lru_redux'

      @client = Kubeclient::Client.new @kubernetes_url, @apiVersion

      @client.ssl_options(
        client_cert: @client_cert.present? ? OpenSSL::X509::Certificate.new(File.read(@client_cert)) : nil,
        client_key:  @client_key.present? ? OpenSSL::PKey::RSA.new(File.read(@client_key)) : nil,
        ca_file:     @ca_file,
        verify_ssl:  @verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
      )

      if @bearer_token_file.present?
        bearer_token = File.read(@bearer_token_file)
        @client.bearer_token(bearer_token)
      end

      begin
        @client.api_valid?
      rescue KubeException => kube_error
        raise Fluent::ConfigError, "Invalid Kubernetes API endpoint: #{kube_error.message}"
      end

      if @cache_ttl < 0
        @cache_ttl = :none
      end
      @cache                                             = LruRedux::TTL::ThreadSafeCache.new(@cache_size, @cache_ttl)
      @container_name_to_kubernetes_name_regexp_compiled = Regexp.compile(@container_name_to_kubernetes_name_regexp)

      if @watch
        thread                    = Thread.new(self) { |this|
          this.start_watch
        }
        thread.abort_on_exception = true
      end
    end

    def filter_stream(tag, es)
      new_es = MultiEventStream.new

      es.each { |time, record|
        if record.has_key?(:docker) && record[:docker].has_key?(:id) && record[:docker].has_key?(:name)
          this                = self
          metadata            = @cache.getset(record[:docker][:id]) {
            match_data = record[:docker][:name].match(@container_name_to_kubernetes_name_regexp_compiled)
            if match_data
              this.get_metadata(
                match_data[:pod_name],
                match_data[:pod_container_name],
                match_data[:namespace]
              )
            end
          }

          record[:kubernetes] = metadata if metadata
        end

        if @merge_json_log
          record = merge_json_log(record)
        end

        new_es.add(time, record)
      }

      new_es
    end

    def merge_json_log(record)
      if record.has_key?('log')
        log = record['log'].strip
        if log[0].eql?('{') && log[-1].eql?('}')
          begin
            parsed_log = JSON.parse(log)
            record = record.merge(parsed_log)
            unless parsed_log.has_key?('log')
              record.delete('log')
            end
          rescue JSON::ParserError
          end
        end
      end
      record
    end

    def start_watch
      resource_version = @client.get_pods.resourceVersion
      watcher          = @client.watch_pods(resource_version)
      watcher.each do |notice|
        case notice.type
          when 'MODIFIED'
            if notice.object.status.containerStatuses
              notice.object.status.containerStatuses.each { |container_status|
                if container_status['containerId']
                  containerId = container_status['containerId'].sub(/^docker:\/\//, '')
                  cached      = @cache[containerId]
                  if cached
                    # Only thing that can be modified is labels
                    cached[:labels]     = v.object.metadata.labels.to_h
                    @cache[containerId] = cached
                  end
                end
              }
            end
          when 'DELETED'
            if notice.object.status.containerStatuses
              notice.object.status.containerStatuses.each { |container_status|
                if container_status['containerId']
                  @cache.delete(container_status['containerId'].sub(/^docker:\/\//, ''))
                end
              }
            end
          else
            # ignoring...
        end
      end
    end
  end
end
