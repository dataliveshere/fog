require 'digest/sha2'
require 'fog/storage'
require 'time'
require_relative './vsphere_connection'

module Fog
  module Storage
    class Vsphere < Fog::Service

      requires :vsphere_server
      recognizes :vsphere_username, :vsphere_password
      recognizes :vsphere_port, :vsphere_path, :vsphere_ns
      recognizes :vsphere_rev, :vsphere_ssl, :vsphere_expected_pubkey_hashs
      recognizes 'clusters', 'share_datastore_pattern', 'local_datastore_pattern', 'log_level'
      recognizes :cert, :key, :extension_key

      model_path 'fog/vsphere/models/storage'
      collection  :volumes
      model       :volume

      request_path 'fog/vsphere/requests/storage'
      request :vm_create_disk
      request :query_resources
      request :keep_alive


      module Shared

        attr_reader :vsphere_is_vcenter
        attr_reader :vsphere_rev
        attr_reader :vsphere_server
        attr_reader :vsphere_username

        DEFAULT_SCSI_KEY ||= 1000
        # SCSI control cannot hang on 7th channel, we need to skip it
        DISK_DEV_LABEL ||= "abcdefghi#jklmnopqrstuvwxyz"

        ATTR_TO_PROP ||= {
            :id => 'config.instanceUuid',
            :name => 'name',
            :uuid => 'config.uuid',
            :instance_uuid => 'config.instanceUuid',
            :hostname => 'summary.guest.hostName',
            :operatingsystem => 'summary.guest.guestFullName',
            :ipaddress => 'guest.ipAddress',
            :power_state => 'runtime.powerState',
            :connection_state => 'runtime.connectionState',
            :hypervisor => 'runtime.host',
            :tools_state => 'guest.toolsStatus',
            :tools_version => 'guest.toolsVersionStatus',
            :is_a_template => 'config.template',
            :memory_mb => 'config.hardware.memoryMB',
            :cpus   => 'config.hardware.numCPU',
        }

        def convert_vm_mob_ref_to_attr_hash(vm_mob_ref)
          return nil unless vm_mob_ref

          props = vm_mob_ref.collect! *ATTR_TO_PROP.values.uniq
          # NOTE: Object.tap is in 1.8.7 and later.
          # Here we create the hash object that this method returns, but first we need
          # to add a few more attributes that require additional calls to the vSphere
          # API. The hypervisor name and mac_addresses attributes may not be available
          # so we need catch any exceptions thrown during lookup and set them to nil.
          #
          # The use of the "tap" method here is a convenience, it allows us to update the
          # hash object without explicitly returning the hash at the end of the method.
          Hash[ATTR_TO_PROP.map { |k,v| [k.to_s, props[v]] }].tap do |attrs|
            attrs['id'] ||= vm_mob_ref._ref
            attrs['mo_ref'] = vm_mob_ref._ref
            # The name method "magically" appears after a VM is ready and
            # finished cloning.
            if attrs['hypervisor'].kind_of?(RbVmomi::VIM::HostSystem) then
              # If it's not ready, set the hypervisor to nil
              attrs['hypervisor'] = attrs['hypervisor'].name rescue nil
            end
            # This inline rescue catches any standard error.  While a VM is
            # cloning, a call to the macs method will throw and NoMethodError
            attrs['mac_addresses'] = vm_mob_ref.macs rescue nil
            attrs['path'] = get_folder_path(vm_mob_ref.parent)
          end
        end

        class HostResource
          attr_accessor :mob
          attr_accessor :name
          attr_accessor :cluster            # this host belongs to which cluster
          attr_accessor :local_datastores
          attr_accessor :share_datastores
          attr_accessor :connection_state
          attr_accessor :place_share_datastores
          attr_accessor :place_local_datastores

          def local_sum
            sum = 0
            return sum if local_datastores.nil?
            local_datastores.values.each {|x| sum += x.real_free_space }
            sum
          end

          def share_sum
            sum = 0
            return sum if share_datastores.nil?
            share_datastores.values.each {|x| sum += x.real_free_space }
            sum
          end

        end

        class DatastoreResource
          attr_accessor :mob
          attr_accessor :name
          attr_accessor :shared # boolean represents local or shared
          attr_accessor :total_space
          attr_accessor :free_space
          attr_accessor :unaccounted_space

          def real_free_space
            if (@free_space - @unaccounted_space) < 0
              real_free = 0
            else
              real_free = (@free_space - @unaccounted_space)
            end
            real_free
          end

          def initialize
            @unaccounted_space = 0
          end

          def deep_clone
            _deep_clone({})
          end

          protected
          def _deep_clone(cloning_map)
            return cloning_map[self] if cloning_map.key? self
            cloning_obj = clone
            cloning_map[self] = cloning_obj
            cloning_obj.instance_variables.each do |var|
              val = cloning_obj.instance_variable_get(var)
              begin
                val = val._deep_clone(cloning_map)
              rescue TypeError
                next
              end
              cloning_obj.instance_variable_set(var, val)
            end
            cloning_map.delete(self)
          end
        end

        class Disk
          attr_accessor :type # system or swap or data
          attr_accessor :shared  # local or shared
          attr_accessor :mode # thin or thick_eager_zeroed or thick_lazy_zeroed
          attr_accessor :affinity # split or not
          attr_accessor :volumes # volumes
          attr_accessor :size # total size
          attr_accessor :bisect # bisect or not

          def initialize(options = {})
            @type =  options['type']
            @mode = options['mode']
            #@affinity = options['affinity'] && true
            @size = options['size']
            @shared = options['shared'] || false
            @affinity = @shared
            @volumes = {}
            @bisect = options['bisect'] || false
          end

        end

        class VM
          attr_accessor :id
          attr_accessor :name
          attr_accessor :host_mob
          attr_accessor :host_name
          attr_accessor :req_mem # requried mem
          attr_accessor :system_disks # Disk
          attr_accessor :swap_disks # Disk
          attr_accessor :data_disks # Disk
          attr_accessor :disk_index # mapped to unit_number(depracated now)
          attr_accessor :datastore_pattern

          def initialize(options = {})
            Fog::Logger.debug("fog: options['system_shared'] = #{options['system_shared']}")
            Fog::Logger.debug("fog: options['data_shared'] = #{options['data_shared']}")
            @name = options['name']
            @req_mem = options['req_mem']
            @datastore_pattern = options['datastore_pattern']
            options['type'] = 'system'
            options['affinity'] = true
            options['size'] = options['system_size']
            if options['system_shared'].nil?
              options['shared'] = true
            else
              options['shared'] = options['system_shared']
            end
            options['mode'] = 'thin' if options['shared']
            @system_disks = Disk.new(options)
            options['type'] = 'swap'
            options['affinity'] = true
            options['size'] = options['swap_size'] || @req_mem
            @swap_disks = Disk.new(options)
            options['type'] = 'data'
            options['affinity'] = false
            options['size'] = options['data_size']
            options['bisect'] = options['disk_bisect']
            @data_disks = Disk.new(options)
            @disk_index = { 'lsilogic'=> 0, 'paravirtual'=> 0 }
          end

          def get_volumes_for_os(type)
            case type
              when 'system'
                vs = system_disks.volumes.values
                returns  = vs.collect{ |v| "/dev/sd#{DISK_DEV_LABEL[v.unit_number]}"}.compact.sort
              when 'swap'
                vs = swap_disks.volumes.values
                returns  = vs.collect{ |v| "/dev/sd#{DISK_DEV_LABEL[v.unit_number]}"}.compact.sort
              when 'data'
                vs = data_disks.volumes.values
                if data_disks.affinity
                  series_number = 0
                else
                  series_number = system_disks.volumes.size + swap_disks.volumes.size
                end
                #returns  = vs.collect{ |v| "/dev/sd#{DISK_DEV_LABEL[series_number + (data_disks.volumes.size - v.unit_number - 1)]}"}.compact.sort
                returns  = vs.collect{ |v| "/dev/sd#{DISK_DEV_LABEL[series_number + v.unit_number]}"}.compact.sort
            end
            returns
          end

          def get_system_ds_name
            name = @system_disks.volumes.values[0].datastore_name
            Fog::Logger.debug("fog: vm.system_disks.name = #{name}[/]")
            name
          end

          def volume_add(type, id, mode, size, fullpath, datastore_name, transport, unit_number)
            v = Volume.new
            v.type = type
            v.vm_mo_ref = id
            v.mode = mode
            v.fullpath = fullpath
            v.size = size
            v.datastore_name = datastore_name
            v.scsi_key = DEFAULT_SCSI_KEY
            v.transport = transport
            v.unit_number = unit_number
            case type
              when 'system'
                system_disks.volumes[fullpath] = v
              when 'swap'
                swap_disks.volumes[fullpath] = v
              when 'data'
                data_disks.volumes[fullpath] = v
              else
                data_disks.volumes[fullpath] = v
            end
            v
          end

          def inspect_volume_size
            Fog::Logger.debug(" vm.system_disks.volumes.size = #{@system_disks.volumes.size}[/]")
            Fog::Logger.debug(" vm.swap_disks.volumes.size = #{@swap_disks.volumes.size}[/]")
            Fog::Logger.debug(" vm.data_disks.volumes.size = #{@data_disks.volumes.size}[/]")
          end

          def inspect_fullpath
            Fog::Logger.debug(" start traverse vm.system_disks.volumes:[/]")
            @system_disks.volumes.values.each do |v|
              Fog::Logger.debug(" vm #{name} system_disks - fullpath = #{v.fullpath} with unit_number = #{v.unit_number}[/]")
            end
            Fog::Logger.debug(" end [/]")
            Fog::Logger.debug(" start traverse vm.swap_disks.volumes:[/]")
            @swap_disks.volumes.values.each do |v|
              Fog::Logger.debug(" vm #{name} swap_disks - fullpath = #{v.fullpath} with unit_number = #{v.unit_number}[/]")
            end
            Fog::Logger.debug(" end [/]")
            Fog::Logger.debug(" start traverse vm.data_disks.volumes:[/]")
            @data_disks.volumes.values.each do |v|
              Fog::Logger.debug(" vm #{name} data_disks - fullpath = #{v.fullpath} with unit_number = #{v.unit_number}[/]")
            end
            Fog::Logger.debug(" end [/]")
          end

        end # end of VM

      end # end of shared module


      class Mock

        include Shared

        def initialize(options={})
          require 'rbvmomi'
          @vsphere_username = options[:vsphere_username]
          @vsphere_password = 'REDACTED'
          @vsphere_server   = options[:vsphere_server]
          @vsphere_expected_pubkey_hash = options[:vsphere_expected_pubkey_hash]
          @vsphere_is_vcenter = true
          @vsphere_rev = '4.0'
        end

      end

      class Real

        include Shared

        def initialize(options={})
          Fog::Logger.set_log_level(options['log_level'])
          # used to initialize resource list
          @share_datastore_pattern = options['share_datastore_pattern']
          Fog::Logger.debug("fog: input share_datastore_pattern is #{options['share_datastore_pattern']}[/]")
          @local_datastore_pattern = options['local_datastore_pattern']
          Fog::Logger.debug("fog: input local_datastore_pattern is #{options['local_datastore_pattern']}[/]")
          @clusters = []

          @connection = Fog::VsphereConnection.connect options

          # initially load storage resource
          fetch_resources(options['clusters'])
        end

        def close
          @connection.close
          @connection = nil
        rescue RbVmomi::fault => e
          raise Fog::Vsphere::Errors::ServiceError, e.message
        end

        def fetch_resources(clusters = nil)
          if !(clusters.nil?)
            clusters.each {|c_name| @clusters << get_mob_ref_by_name('ComputeResource',c_name)}
            Fog::Logger.debug("fog: fetch resource input")
            @clusters.each do |cs_mob_ref|
              Fog::Logger.debug("fog: @cluster has a cluster which mob ref is #{cs_mob_ref}")
            end
            Fog::Logger.debug("fog: end")
          end
          if @clusters.size <=0
            Fog::Logger.debug(" can not load into storage resources without clusters argument[/]")
          else
            fetch_host_storage_resource()
          end
        end

        def query_capacity(vms, options = {})
          if options.has_key?('share_datastore_pattern') || options.has_key?('local_datastore_pattern')
            fetch_host_storage_resource(
                'hosts' => options['hosts'],
                'share_datastore_pattern' => options['share_datastore_pattern'],
                'local_datastore_pattern' => options['local_datastore_pattern']
            )
          end
          total_share_req_size = 0
          total_local_req_size = 0
          vms.each do |vm|
            if vm.system_disks.shared
              total_share_req_size += vm.system_disks.size
            else
              Fog::Logger.debug("fog: required system size = #{vm.system_disks.size.to_s}")
              total_local_req_size += vm.system_disks.size
            end
            if vm.data_disks.shared
              total_share_req_size += vm.data_disks.size
            else
              total_local_req_size += vm.data_disks.size
            end
            if vm.swap_disks.shared
              total_share_req_size += vm.swap_disks.size
            else
              total_local_req_size += vm.swap_disks.size
            end
          end
          fit_hosts = []
          options['hosts'].each do |host_name|
            if @host_list.has_key?(host_name)
              Fog::Logger.debug(" @host_list[host_name].share_datastores.values")
              @host_list[host_name].share_datastores.values.each do |ds|
                Fog::Logger.debug(" ds name #{ds.name} ds free #{ds.real_free_space}")
              end
              Fog::Logger.debug(" @host_list[host_name].local_datastores.values")
              @host_list[host_name].local_datastores.values.each do |ds|
                Fog::Logger.debug(" ds name #{ds.name} ds free #{ds.real_free_space}")
              end
              Fog::Logger.debug("fog: @host_list[#{host_name}].local_sum=#{@host_list[host_name].local_sum} total_local_req_size = #{total_local_req_size}")
              Fog::Logger.debug("fog: @host_list[#{host_name}].share_sum=#{@host_list[host_name].share_sum} total_share_req_size = #{total_share_req_size}")
              next if @host_list[host_name].connection_state != 'connected'
              next if @host_list[host_name].local_sum < total_local_req_size
              next if @host_list[host_name].share_sum < total_share_req_size
              fit_hosts << host_name
              Fog::Logger.debug("fog: host number #{fit_hosts.size}")
            end
          end
          fit_hosts
        end

        def select_hosts_for_datadisk_with_bisect(host_name, datastore_candidates, hosts_pseudo_bisect, vm, buffer_size)
          data_done = false
          real_bisect = false # indicate whether the splited disks are put on different datastores or not
          candidates = datastore_candidates.clone
          split_size = vm.data_disks.size/2
          candidates.each do |ds|
            if ds.real_free_space <= split_size + buffer_size
              Fog::Logger.debug("fog: datastore #{ds.name} cannot provide enough space for data disk with bisect mode")
              datastore_candidates.delete(ds)
            end
          end

          if datastore_candidates.size >= 2
            alloc_volumes(host_name, 'data', vm, datastore_candidates[0..1], split_size)
            data_done = true
            real_bisect = true
          elsif datastore_candidates.size == 1 && datastore_candidates[0].real_free_space > vm.data_disks.size + buffer_size
            alloc_volumes(host_name, 'data', vm, [ datastore_candidates[0] ], split_size)
            alloc_volumes(host_name, 'data', vm, [ datastore_candidates[0] ], split_size)
            hosts_pseudo_bisect << host_name unless hosts_pseudo_bisect.include?(host_name)
            data_done = true
          else
            Fog::Logger.debug(" there is no enough space to place data disks for vm #{vm.name} with host #{host_name}")
          end

          return data_done, real_bisect
        end

        def retrieve_candidates(disk, host)
          if disk.shared && !(host.share_datastores.empty?)
            datastore_candidates = host.share_datastores.values.clone
          else
            datastore_candidates = host.local_datastores.values.clone
          end
          datastore_candidates = datastore_candidates.sort {|x,y| y.real_free_space <=> x.real_free_space}
          datastore_candidates
        end

        def calc_datastores_capacity(vm, datastore_candidates, buffer_size)
          candidates = datastore_candidates.clone
          sum = 0
          candidates.each do |x|
            if !(vm.datastore_pattern.nil?)
              if isMatched?(x.name, vm.datastore_pattern)
                Fog::Logger.debug("fog: input ds name #{x.name} with matched pattern")
              else
                Fog::Logger.debug("fog: input ds name #{x.name} without matched pattern")
                datastore_candidates.delete(x)
                next
              end
            end
            if x.real_free_space <= buffer_size
              datastore_candidates.delete(x)
              next
            end
            sum += x.real_free_space
          end
          sum
        end

        def recommendation(vms,hosts)
          solution_list = {}
          hosts_pseudo_bisect = []
          real_bisect = false
          affinity = vms[0].data_disks.affinity
          Fog::Logger.debug("fog: @host_list number #{@host_list.keys.size}")
          hosts = hosts.sort {|x,y| @host_list[y].local_sum <=> @host_list[x].local_sum}
          hosts.each do |host_name|
            real_bisect_for_this_host = true
            @cached_ds = nil
            Fog::Logger.debug("fog: for each host named #{host_name} to place disk")
            next unless @host_list.has_key?(host_name)
            Fog::Logger.debug("fog: @host_list[#{host_name}].local_sum = #{@host_list[host_name].local_sum}")
            solution_list[host_name]=[]
            vms.each do |vm_in_queue|
              vm = Marshal.load(Marshal.dump(vm_in_queue))
              Fog::Logger.debug("fog: input vm_datastore_pattern is #{vm.datastore_pattern}[/]")
              datastore_candidates = retrieve_candidates(vm.system_disks, @host_list[host_name])

              if !(@cached_ds.nil?) && datastore_candidates.include?(@cached_ds)
                datastore_candidates.delete(@cached_ds)
                datastore_candidates.unshift(@cached_ds)
              end

              system_done = false
              swap_done = false
              sum = 0
              buffer_size = 512
              
              sum = calc_datastores_capacity(vm, datastore_candidates, buffer_size)
              if sum < (vm.req_mem + vm.system_disks.size + vm.swap_disks.size)
                Fog::Logger.debug(" there is no enough space for vm #{vm.name} with host #{host_name} left #{sum}")
              else
                Fog::Logger.debug("fog: system ds chosen for host #{host_name}")
                datastore_candidates.each do |ds|
                  Fog::Logger.debug("fog: ds for host #{host_name} name: #{ds.name}, real_free_space: #{ds.real_free_space}")
                end
                Fog::Logger.debug("fog: end")

                # place system_disks and swap_disks
                datastore_candidates.each do |ds|
                  if ds.real_free_space >= (vm.req_mem + vm.system_disks.size + vm.swap_disks.size)
                    alloc_volumes(host_name, 'system', vm, [ds], vm.system_disks.size)
                    system_done = true
                    alloc_volumes(host_name, 'swap', vm, [ds], vm.swap_disks.size)
                    swap_done = true
                    @cached_ds = ds
                    break
                  elsif ds.real_free_space >= (vm.req_mem + vm.system_disks.size)
                    alloc_volumes(host_name, 'system', vm, [ds], vm.system_disks.size)
                    system_done = true
                    break if swap_done
                  elsif ds.real_free_space < (vm.req_mem + vm.system_disks.size)&& ds.real_free_space>= vm.swap_disks.space
                    alloc_volumes(host_name, 'swap', vm, [ds], vm.swap_disks.size)
                    swap_done = true
                    break if system_done
                  end
                end # end of ds_candidate traverse
              end
              if !system_done || !swap_done
                Fog::Logger.debug(" there is no enough space for vm #{vm.name} on host#{host_name} for system disk") unless system_done && swap_done
                recovery(solution_list[host_name]) unless !(solution_list.has_key?(host_name)) || solution_list[host_name].nil?
                solution_list.delete(host_name)
                break
              end

              # place data disks
              if (vm.data_disks.size > 0)
                datastore_candidates = retrieve_candidates(vm.data_disks, @host_list[host_name])
                sum = 0
                data_done = false
                sum = calc_datastores_capacity(vm, datastore_candidates, buffer_size)
                Fog::Logger.debug("fog: sum = #{sum} but reburied is #{vm.data_disks.size}")
                if sum < vm.data_disks.size
                  Fog::Logger.debug(" there is no enough space for vm #{vm.name} with host #{host_name} left #{sum}")
                else
                  Fog::Logger.debug("fog: data ds chosen for host #{host_name}")
                  datastore_candidates.each do |ds|
                    Fog::Logger.debug("fog: ds for host #{host_name} name: #{ds.name}, real_free_space: #{ds.real_free_space}")
                  end
                  if vm.data_disks.bisect # use bisect algorithm
                    data_done, real_bisect_for_this_vm = select_hosts_for_datadisk_with_bisect(host_name, datastore_candidates, hosts_pseudo_bisect, vm, buffer_size)
                    real_bisect_for_this_host &= real_bisect_for_this_vm
                  elsif affinity # use affinity algorithm
                    available_size = 0
                    left_size = vm.data_disks.size
                    datastore_candidates.each do |ds|
                      available_size = ds.real_free_space - buffer_size
                      if available_size >= left_size
                        Fog::Logger.debug("fog: for vm #{vm.name} allocated size= #{left_size} from ds #{ds.name}")
                        alloc_volumes(host_name, 'data', vm, [ds], left_size)
                        data_done = true
                        break
                      else
                        Fog::Logger.debug("fog: for vm #{vm.name} allocated size= #{available_size} from ds #{ds.name} left #{left_size} not alloced")
                        alloc_volumes(host_name, 'data', vm, [ds], available_size)
                        left_size -= available_size
                      end
                    end
                  else #use anti-affinity algorithm
                    allocated_size = vm.data_disks.size/datastore_candidates.size
                    number = datastore_candidates.size
                    req_size = vm.data_disks.size
                    length = number
                    arr_index = 0

                    datastore_candidates.each do |ds|
                      if allocated_size <= (ds.real_free_space - buffer_size)
                        alloc_volumes(host_name, 'data', vm, datastore_candidates[arr_index..length], allocated_size)
                        data_done = true
                        break
                      else
                        arr_index +=1
                        allocated_size = (ds.real_free_space - buffer_size)
                        alloc_volumes(host_name, 'data', vm, [ds], allocated_size)
                        req_size -= allocated_size
                        number -=1
                        if number > 0
                          allocated_size = req_size/number
                        elsif number == 0
                          allocated_size = req_size
                          data_done = true
                        end
                      end
                    end
                  end
                end

                if !data_done #|| vm.system_disks.volumes.empty? || vm.swap_disks.volumes.values.empty?
                  Fog::Logger.warning("there is no enough space for vm #{vm.name} on host#{host_name} for data disk")
                  Fog::Logger.warning("vm#{vm.name}.system_disks.volumes.empty? is true") if vm.system_disks.volumes.empty?
                  Fog::Logger.warning("vm#{vm.name}.wap_disks.volumes.empty? is true") if vm.swap_disks.volumes.empty?
                  recovery(solution_list[host_name]) unless !(solution_list.has_key?(host_name)) || solution_list[host_name].nil?
                  solution_list.delete(host_name)
                  break
                end
              end
              solution_list[host_name] << vm
            end # end of vms traverse
            real_bisect |= real_bisect_for_this_host
          end  # end of hosts traverse

          # if there exists hosts that can bisect the data disk and put on different datastores,
          # recovery those that can only put splitted data disks on a same datastore.
          if real_bisect && !hosts_pseudo_bisect.empty?
            hosts_pseudo_bisect.each do |host_name|
              recovery(solution_list[host_name]) unless !(solution_list.has_key?(host_name)) || solution_list[host_name].nil?
              solution_list.delete(host_name)
            end
          end

          solution_list.keys.each do |host_name|
            vms = solution_list[host_name]
            recovery(vms)
          end # end of solution_list traverse

          solution_list
        end

        def commission(vms)
          Fog::Logger.debug(" enter commission methods[/]")
          original_size = @host_list[vms[0].host_name].local_sum + @host_list[vms[0].host_name].share_sum
          Fog::Logger.debug(" original size = #{original_size}[/]")
          difference = 0
          vms.each do |vm|
            is_shared = vm.system_disks.shared

            vm.system_disks.volumes.values.each do |v|
              if is_shared && !(@host_list[vm.host_name].share_datastores.empty?)
                @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space += (v.size.to_i + vm.req_mem.to_i)
                if @host_list[vm.host_name].local_datastores.has_key? (v.datastore_name)
                  @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space += (v.size.to_i + vm.req_mem.to_i)
                end
              else
                @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space += (v.size.to_i + vm.req_mem.to_i)
                if @host_list[vm.host_name].share_datastores.has_key? (v.datastore_name)
                  @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space += (v.size.to_i + vm.req_mem.to_i)
                end
              end
            end

            vm.swap_disks.volumes.values.each do |v|
              if is_shared && !(@host_list[vm.host_name].share_datastores.empty?)
                @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space += v.size.to_i
                if @host_list[vm.host_name].local_datastores.has_key? (v.datastore_name)
                  @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space += v.size.to_i
                end
              else
                @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space += v.size.to_i
                if @host_list[vm.host_name].share_datastores.has_key? (v.datastore_name)
                  @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space += v.size.to_i
                end
              end
            end

            vm.data_disks.volumes.values.each do |v|
              if vm.data_disks.shared && !(@host_list[vm.host_name].share_datastores.empty?)
                Fog::Logger.debug("fog: commit data_disk of size-#{v.size} on #{v.datastore_name} before size=#{@host_list[vm.host_name].share_datastores[v.datastore_name].real_free_space}[/]")
                @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space += v.size.to_i
                if @host_list[vm.host_name].local_datastores.has_key? (v.datastore_name)
                  Fog::Logger.debug("fog: commit data_disk of size-#{v.size} on #{v.datastore_name} before size=#{@host_list[vm.host_name].local_datastores[v.datastore_name].real_free_space}[/]")
                  @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space += v.size.to_i
                end
                Fog::Logger.debug("fog: for vm.name=#{vm.name} after commit result-#{v.datastore_name} share left size=#{@host_list[vm.host_name].share_datastores[v.datastore_name].real_free_space}[/]")
              else
                Fog::Logger.debug("fog: commit data_disk of size-#{v.size} on #{v.datastore_name} before size=#{@host_list[vm.host_name].local_datastores[v.datastore_name].real_free_space}[/]")
                @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space += v.size.to_i
                if @host_list[vm.host_name].share_datastores.has_key? (v.datastore_name)
                  Fog::Logger.debug("fog: commit data_disk of size-#{v.size} on #{v.datastore_name} before size=#{@host_list[vm.host_name].share_datastores[v.datastore_name].real_free_space}[/]")
                  @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space += v.size.to_i
                end
                Fog::Logger.debug("fog: for vm.name=#{vm.name} after commit result-#{v.datastore_name} local left size=#{@host_list[vm.host_name].local_datastores[v.datastore_name].real_free_space}[/]")
              end
            end

          end

          Fog::Logger.debug(" finish commission methods[/]")
          difference = original_size - @host_list[vms[0].host_name].local_sum - @host_list[vms[0].host_name].share_sum
          Fog::Logger.debug(" commit size = #{difference}[/]")
          difference
        end


        def decommission(vms)
          return 0 if vms.size <= 0
          Fog::Logger.debug(" enter decommission methods[/]")
          original_size = @host_list[vms[0].host_name].local_sum + @host_list[vms[0].host_name].share_sum
          Fog::Logger.debug(" original size = #{original_size}[/]")
          difference = 0
          vms.each do |vm|
            is_shared = vm.system_disks.shared

            vm.system_disks.volumes.values.each do |v|
              if is_shared && !(@host_list[vm.host_name].share_datastores.empty?)
                @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space -= (v.size.to_i + vm.req_mem.to_i)
                if @host_list[vm.host_name].local_datastores.has_key? (v.datastore_name)
                  @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space -= (v.size.to_i + vm.req_mem.to_i)
                end
              else
                @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space -= (v.size.to_i + vm.req_mem.to_i)
                if @host_list[vm.host_name].share_datastores.has_key? (v.datastore_name)
                  @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space -= (v.size.to_i + vm.req_mem.to_i)
                end
              end
            end

            vm.swap_disks.volumes.values.each do |v|
              if is_shared && !(@host_list[vm.host_name].share_datastores.empty?)
                @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space -= v.size.to_i
                if @host_list[vm.host_name].local_datastores.has_key? (v.datastore_name)
                  @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space -= v.size.to_i
                end
              else
                @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space -= v.size.to_i
                if @host_list[vm.host_name].share_datastores.has_key? (v.datastore_name)
                  @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space -= v.size.to_i
                end
              end
            end

            vm.data_disks.volumes.values.each do |v|

              if vm.data_disks.shared && !(@host_list[vm.host_name].share_datastores.empty?)
                Fog::Logger.debug("fog: decommit data_disk of size-#{v.size} on #{v.datastore_name} before size=#{@host_list[vm.host_name].share_datastores[v.datastore_name].real_free_space}[/]")
                @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space -= v.size.to_i
                if @host_list[vm.host_name].local_datastores.has_key? (v.datastore_name)
                  Fog::Logger.debug("fog: decommit data_disk of size-#{v.size} on #{v.datastore_name} before size=#{@host_list[vm.host_name].local_datastores[v.datastore_name].real_free_space}[/]")
                  @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space -= v.size.to_i
                end
                Fog::Logger.debug("fog: for vm.name=#{vm.name} after decommit result-#{v.datastore_name} share left size=#{@host_list[vm.host_name].share_datastores[v.datastore_name].real_free_space}[/]")
              else
                Fog::Logger.debug("fog: decommit data_disk of size-#{v.size} on #{v.datastore_name} before size=#{@host_list[vm.host_name].local_datastores[v.datastore_name].real_free_space}[/]")
                @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space -= v.size.to_i
                if @host_list[vm.host_name].share_datastores.has_key? (v.datastore_name)
                  Fog::Logger.debug("fog: decommit data_disk of size-#{v.size} on #{v.datastore_name} before size=#{@host_list[vm.host_name].share_datastores[v.datastore_name].real_free_space}[/]")
                  @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space -= v.size.to_i
                end
                Fog::Logger.debug("fog: for vm.name=#{vm.name} after decommit result-#{v.datastore_name} local left size=#{@host_list[vm.host_name].local_datastores[v.datastore_name].real_free_space}[/]")
              end

            end

          end

          Fog::Logger.debug(" finish decommission methods[/]")
          difference =  @host_list[vms[0].host_name].local_sum + @host_list[vms[0].host_name].share_sum - original_size
          Fog::Logger.debug(" decommit size = #{difference}[/]")
          difference
        end

        def recovery(vms)
          Fog::Logger.debug(" enter recover method[/]")
          vms.each do |vm|
            is_shared = vm.system_disks.shared
            vm.system_disks.volumes.values.each do |v|
              if is_shared && !(@host_list[vm.host_name].share_datastores.empty?)
                @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space -= (v.size.to_i + vm.req_mem.to_i)
              else
                @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space -= (v.size.to_i + vm.req_mem.to_i)
              end
            end
            vm.swap_disks.volumes.values.each do |v|
              if is_shared && !(@host_list[vm.host_name].share_datastores.empty?)
                @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space -= v.size.to_i
              else
                @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space -= v.size.to_i
              end
            end
            vm.data_disks.volumes.values.each do |v|
              if vm.data_disks.shared && !(@host_list[vm.host_name].share_datastores.empty?)
                Fog::Logger.debug("fog: recovery data_disk of size-#{v.size} on #{v.datastore_name} before size=#{@host_list[vm.host_name].share_datastores[v.datastore_name].real_free_space}[/]")
                @host_list[vm.host_name].share_datastores[v.datastore_name].unaccounted_space -= v.size.to_i
                Fog::Logger.debug("fog: for vm.name=#{vm.name} after recovery result-#{v.datastore_name} share left size=#{@host_list[vm.host_name].share_datastores[v.datastore_name].real_free_space}[/]")
              else
                Fog::Logger.debug("fog: recovery data_disk of size-#{v.size} on #{v.datastore_name} before size=#{@host_list[vm.host_name].local_datastores[v.datastore_name].real_free_space}[/]")
                @host_list[vm.host_name].local_datastores[v.datastore_name].unaccounted_space -= v.size.to_i
                Fog::Logger.debug("fog: for vm.name=#{vm.name} after recovery result-#{v.datastore_name} local left size=#{@host_list[vm.host_name].local_datastores[v.datastore_name].real_free_space}[/]")
              end
            end
          end
        end

        def create_volumes(vm)
          Fog::Logger.debug(" enter into volumes_create methods with argument(vm.id = #{vm.id}, vm.host_name =#{vm.host_name})[/]")
          vs = []
          vs += vm.swap_disks.volumes.values
          vs += vm.data_disks.volumes.values.reverse
          response = {}
          recover = []
          collection = self.volumes
          begin
            vs.each do |v|
              #Fog::Logger.debug("fog: create_volumes fullpath#{v.fullpath} transport#{v.transport} unit_number#{v.unit_number}[/]")
              params = {
                  'vm_mo_ref' => vm.id,
                  'mode' => v.mode,
                  'fullpath' => v.fullpath,
                  'size'=> v.size,
                  'type' => v.type,
                  'datastore_name' => v.datastore_name,
                  'transport' => v.transport,
                  'unit_number' => v.unit_number
              }
              next if params['size'] <= 0
              recover << params
              v = collection.new(params)
              response = v.save
              if !response.has_key?('task_state') || response['task_state'] != "success"
                recover.pop
                recover.each do |params|
                  Fog::Logger.debug("fog: create_volumes response fail fullpath=#{params['fullpath']} transport=#{params['transport']}[/]")
                  next if params['size'] <= 0
                  v = collection.new(params)
                  response = v.destroy
                end
                break
              end
            end
          rescue => e
            Fog::Logger.debug("fog: create_volumes error #{e} need recover")
            response['task_state'] = 'error'
            response['error_message'] = e.to_s
            recover.pop
            recover.each do |params|
              Fog::Logger.debug("fog: create_volumes recover fullpath=#{params['fullpath']} transport=#{params['transport']}[/]")
              next if params['size'] <= 0
              v = collection.new(params)
              response = v.destroy
            end
          end
          Fog::Logger.debug(" finish volumes_create methods with argument(#{vm.host_name})[/]")
          response
        end

        def delete_volumes(vm)
          Fog::Logger.debug(" enter into volumes_delete methods with argument(vm.id = #{vm.id}, vm.host_name = #{vm.host_name})[/]")
          vs = []
          vs += vm.swap_disks.volumes.values
          vs += vm.data_disks.volumes.values
          response = {}
          begin
            vs.each do |v|
              params = {
                  'vm_mo_ref' => vm.id,
                  'mode' => v.mode,
                  'fullpath' => v.fullpath,
                  'size'=> v.size,
                  'datastore_name' => v.datastore_name,
                  'transport' => v.transport
              }
              collection = self.volumes
              v = collection.new(params)
              response = v.destroy
              if !response.has_key?('task_state') || response['task_state'] != "success"
                break
              else
                v = nil
              end
            end
          rescue RbVmomi::Fault => e
            response['task_state'] = 'error'
            response['error_message'] = e.to_s
          end
          Fog::Logger.debug(" finish volumes_delete methods with argument(#{vm.host_name})[/]")
          response
        end

        private

        def clone_array(arr_ds_res)
          results = []
          arr.each { |x| results << x.deep_clone }
          results
        end

        def alloc_volumes(host_name, type, vm, ds_res, size)
          vm.host_name = host_name
          transport = 'lsilogic'
          ds_res.each do |ds|
            case type
              when 'system'
                mode =  vm.system_disks.mode
                id = vm.id
              when 'swap'
                mode =  vm.swap_disks.mode
                id = vm.id
              when 'data'
                mode =  vm.data_disks.mode
                id = vm.id
                transport = 'paravirtual' unless vm.data_disks.affinity
              else
                mode =  vm.data_disks.mode
                id = vm.id
                transport = 'paravirtual' unless vm.data_disks.affinity
            end
            unit_number = vm.disk_index[transport]
            vm.disk_index[transport] = unit_number+1
            if vm.disk_index[transport] == 7
              vm.disk_index[transport] = unit_number+2
            end
            if ds.shared
              fullpath = "[#{ds.name}] #{vm.name}/shared#{transport}#{unit_number}.vmdk"
            else
              fullpath = "[#{ds.name}] #{vm.name}/local#{transport}#{unit_number}.vmdk"
            end
            Fog::Logger.debug("fog: alloc type=#{type} transport=#{transport} fullpath=#{fullpath} unit_number=#{unit_number}")
            vm.volume_add(type, id, mode, size, fullpath, ds.name, transport, unit_number)
            if type == 'system'
              ds.unaccounted_space += (size.to_i + vm.req_mem.to_i)
            else
              ds.unaccounted_space += size.to_i
            end
          end

        end


      end  # end of real
    end
  end
end
