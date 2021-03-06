class Container
  include Mongoid::Document
  include Mongoid::Timestamps

  field :container_id, type: String
  field :name, type: String
  field :driver, type: String
  field :exec_driver, type: String
  field :image, type: String
  field :env, type: Array, default: []
  field :network_settings, type: Hash, default: {}
  field :state, type: Hash, default: {}
  field :finished_at, type: Time
  field :started_at, type: Time
  field :deleted_at, type: Time
  field :volumes, type: Array, default: []
  field :deploy_rev, type: String
  field :container_type, type: String, default: 'container'

  validates_uniqueness_of :container_id, scope: [:host_node_id]

  belongs_to :grid
  belongs_to :grid_service
  belongs_to :host_node
  has_many :container_logs
  has_many :container_stats

  index({ grid_id: 1 })
  index({ grid_service_id: 1 })
  index({ host_node_id: 1 })
  index({ updated_at: 1 })
  index({ deleted_at: 1 }, {sparse: true})
  index({ container_id: 1 })
  index({ state: 1 })

  default_scope -> { where(deleted_at: nil, container_type: 'container') }
  scope :deleted, -> { where(deleted_at: {'$ne' => nil}) }
  scope :volumes, -> { where(deleted_at: nil, container_type: 'volume') }

  def to_path
    if self.grid
      "#{self.grid.try(:name)}/#{self.name}"
    else
      self.name
    end
  end

  ##
  # @return [String]
  def status
    return 'deleted' if self.deleted_at

    if self.updated_at.nil? || self.updated_at < (Time.now.utc - 2.minutes)
      return 'unknown'
    end

    s = self.state
    if s['paused']
      'paused'
    elsif s['running']
      'running'
    elsif s['restarting']
      'restarting'
    elsif s['oom_killed']
      'oom_killed'
    else
      'stopped'
    end
  end

  def mark_for_delete
    self.update_attribute(:deleted_at, Time.now.utc)
  end

  def running?
    self.status == 'running'
  end

  def stopped?
    self.status == 'stopped'
  end

  def paused?
    self.status == 'paused'
  end

  def ephemeral?
    self.volumes.nil? || self.volumes.size == 0
  end

  ##
  # @param [Hash] info
  def attributes_from_docker(info)
    self.attributes = {
        container_id: info['Id'],
        driver: info['Driver'],
        exec_driver: info['ExecDriver'],
        image: info['Config']['Image'],
        env: info['Config']['Env'],
        network_settings: self.parse_docker_network_settings(info['NetworkSettings']),
        state: {
            error: info['State']['Error'],
            exit_code: info['State']['ExitCode'],
            pid: info['State']['Pid'],
            oom_killed: info['State']['OOMKilled'],
            paused: info['State']['Paused'],
            restarting: info['State']['Restarting'],
            running: info['State']['Running']
        },
        finished_at: (info['State']['FinishedAt'] ? Time.parse(info['State']['FinishedAt']) : nil),
        started_at: (info['State']['StartedAt'] ? Time.parse(info['State']['StartedAt']) : nil),
        deleted_at: nil,
        volumes: info['Volumes'].map{|k, v| [{container: k, node: v}]}
    }
  end

  ##
  # @param [Hash] network
  # @return [Hash]
  def parse_docker_network_settings(network)
    if network['Ports']
      ports = {}
      network['Ports'].each{|container_port, port_map|
        if port_map
          ports[container_port] = port_map.map{|j| { node_ip: j['HostIp'], node_port: j['HostPort'].to_i}}
        end
      }
    else
      ports = nil
    end

    {
        bridge: network['Bridge'],
        gateway: network['Gateway'],
        ip_address: network['IPAddress'],
        ip_prefix_len: network['IPPrefixLen'],
        mac_address: network['MacAddress'],
        port_mapping: network['PortMapping'],
        ports: ports
    }
  end

  ##
  # @return [Boolean]
  def exists_on_node?
    return false if self.container_id.blank? || !self.host_node

    self.host_node.rpc_client.request('/containers/show', self.container_id.to_s)
    true
  rescue RpcClient::Error => e
    if e.code == 404
      false
    else
      raise e
    end
  end
end
