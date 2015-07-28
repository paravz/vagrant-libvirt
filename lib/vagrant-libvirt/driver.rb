require 'fog/libvirt'
require 'log4r'

module VagrantPlugins
  module ProviderLibvirt
    class Driver

      # store the connection at the process level
      #
      # possibly this should be a connection pool using the connection
      # settings as a key to allow per machine connection attributes
      # to be used.
      @@connection = nil

      def initialize(machine)
        @logger = Log4r::Logger.new('vagrant_libvirt::driver')
        @machine = machine
      end

      def connection
        # If already connected to libvirt, just use it and don't connect
        # again.
        return @@connection if @@connection

        # Get config options for libvirt provider.
        config = @machine.provider_config
        uri = config.uri

        conn_attr = {}
        conn_attr[:provider] = 'libvirt'
        conn_attr[:libvirt_uri] = uri
        conn_attr[:libvirt_username] = config.username if config.username
        conn_attr[:libvirt_password] = config.password if config.password

        # Setup command for retrieving IP address for newly created machine
        # with some MAC address. Get it from dnsmasq leases table
        ip_command = %q[ awk "/$mac/ {print \$1}" /proc/net/arp ]
        conn_attr[:libvirt_ip_command] = ip_command

        @logger.info("Connecting to Libvirt (#{uri}) ...")
        begin
          @@connection = Fog::Compute.new(conn_attr)
        rescue Fog::Errors::Error => e
          raise Errors::FogLibvirtConnectionError,
            :error_message => e.message
        end

        @@connection
      end

      def get_domain(mid)
        begin
          domain = connection.servers.get(mid)
        rescue Libvirt::RetrieveError => e
          if e.libvirt_code == ProviderLibvirt::Util::ErrorCodes::VIR_ERR_NO_DOMAIN
            @logger.debug("machine #{mid} not found #{e}.")
            return nil
          else
            raise e
          end
        end

        domain
      end

      def created?(mid)
        domain = get_domain(mid)
        !domain.nil?
      end

      def get_ipaddress(machine)
        # Find the machine
        domain = get_domain(machine.id)

        if domain.nil?
          # The machine can't be found
          return nil
        end

        # Get IP address from arp table
        ip_address = nil
        begin
          domain.wait_for(2) do
            addresses.each_pair do |type, ip|
              # Multiple leases are separated with a newline, return only
              # the most recent address
              ip_address = ip[0].split("\n").first if ip[0] != nil
            end
            ip_address != nil
          end
        rescue Fog::Errors::TimeoutError
          @logger.info("Timeout at waiting for an ip address for machine %s" % machine.name)
        end

        if not ip_address
          @logger.info("No arp table entry found for machine %s" % machine.name)
          return nil
        end

        ip_address
      end

      def state(machine)
        # TODO: while this currently matches the previous behaviour in actions
        # read_state, it shouldn't be necessary to loop and wait for the
        # machine to reach a state other than shutting-down, before returning

        # may be other error states with initial retreival we can't handle
        begin
          domain = get_domain(machine.id)
        rescue Libvirt::RetrieveError => e
          @logger.debug("Machine #{machine.id} not found #{e}.")
          return :not_created
        end

        # need to wait for the shutting-down state to stablize to a another
        loop do
          if domain.nil? || domain.state.to_sym == :terminated
            return :not_created
          end

          if domain.state.to_sym != :'shutting-down'
            # Return the state
            return domain.state.to_sym
          end

          @logger.info('Waiting on the machine %s to shut down...' % machine.name)
          sleep 1
          domain = get_domain(machine.id)
        end
      end
    end
  end
end
