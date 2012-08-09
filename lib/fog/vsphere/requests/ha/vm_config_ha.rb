module Fog
  module Highavailability
    class Vsphere

      module Shared

        def wait_for_task(task)
          state = task.info.state
          while (state != 'error') and (state != 'success')
            sleep(2)
            state = task.info.state
          end
          case state
            when 'success'
              task.info.result
            when 'error'
              raise task.info.error
          end
        end

        private

        def get_vm_mob_ref_by_moid(vm_moid)
          raise ArgumentError, "Must pass a vm management object id" unless vm_moid
          vm_mob_ref = RbVmomi::VIM::VirtualMachine.new(@connection,vm_moid)
          vm_mob_ref
        end

        def get_host_mob_ref_by_moid(host_moid)
          raise ArgumentError, "Must pass a host management object id" unless host_moid
          host_mob_ref = RbVmomi::VIM::HostSystem.new(@connection, host_moid)
          host_mob_ref
        end

        def get_parent_cs_by_vm_mob(vm_mob_ref)
          mob_ref = vm_mob_ref.resourcePool.owner
          while !(mob_ref.kind_of? RbVmomi::VIM::ComputeResource)
            mob_ref = mob_ref.parent
          end
          mob_ref
        end

      end

      class Real
        include Shared

        def is_vm_in_ha_cluster(options = {})
          raise ArgumentError, "Must pass a vm_moid option" unless options['vm_moid']
          vm_mob_ref = get_vm_mob_ref_by_moid(options['vm_moid'])
          cs_mob_ref = get_parent_cs_by_vm_mob(vm_mob_ref)
          if cs_mob_ref.configuration.dasConfig
            ha_enable = cs_mob_ref.configuration.dasConfig.enabled
          else
            ha_enable = false
          end
          ha_enable
        end

        def vm_disable_ft(options ={})
          raise ArgumentError, "Must pass a vm_moid option" unless options['vm_moid']
          vm_mob_ref = get_vm_mob_ref_by_moid(options['vm_moid'])
          if vm_mob_ref.runtime.faultToleranceState == "notConfigured"
            return { 'task_state' => 'success' }
          end
          ft_info = vm_mob_ref.config.ftInfo
          return { 'task_state' => 'error' } if ft_info.nil?
          if ft_info.kind_of?(RbVmomi::VIM::FaultToleranceSecondaryConfigInfo)
            Fog::Logger.deprecation("RbVmomi::VIM::FaultToleranceSecondaryConfigInfo = #{ft_info.primaryVM}")
            vm_mob_ref = ft_info.primaryVM
          else
            Fog::Logger.deprecation("RbVmomi::VIM::FaultTolerancePrimaryConfigInfo = #{ft_info.secondaries}")
          end
          begin
            task = vm_mob_ref.TurnOffFaultToleranceForVM_Task()
            wait_for_task(task)
          rescue => e
            puts e.to_s
            return e
          end
          { 'task_state' => task.info.state }
        end


        def vm_enable_ft(options = {})
          raise ArgumentError, "Must pass a vm_moid option" unless options['vm_moid']
          #raise ArgumentError, "Must pass a host_moid option" unless options['host_moid']
            vm_mob_ref = get_vm_mob_ref_by_moid(options['vm_moid'])
            #host_mob_ref = get_host_mob_ref_by_moid(options['host_moid'])
            begin
              task = vm_mob_ref.CreateSecondaryVM_Task()
              wait_for_task(task)
            rescue => e
              if e.kind_of?(RbVmomi::Fault)
                return e.errors
              else
                return e
              end
            end
            { 'task_state' => task.info.state }
        end


        def vm_disable_ha(options = {})
         raise ArgumentError, "Must pass a vm_moid option" unless options['vm_moid']
         vm_mob_ref = get_vm_mob_ref_by_moid(options['vm_moid'])
         cs_mob_ref = get_parent_cs_by_vm_mob(vm_mob_ref)
         ha_enable = is_vm_in_ha_cluster('vm_moid' => options['vm_moid'])
         if !ha_enable
           return { 'task_state' => 'error'}
         end

         das_vm_priority = nil
         vm_das_config = nil
         vm_ha_spec = nil

         vm_das_configs = cs_mob_ref.configuration.dasVmConfig


         vm_das_configs.each{|d|
             if d[:key]._ref.to_s == options['vm_moid']
               vm_das_config = d

               if vm_das_config #&& vm_das_config.dasSettings
                 das_vm_priority = vm_das_config.restartPriority
               end

               if das_vm_priority && das_vm_priority == "disabled"
                 return  { 'task_state' => 'success' }
               else
                 vm_ha_spec_info = RbVmomi::VIM::ClusterDasVmConfigInfo(
                     :key=>vm_mob_ref,
                     :restartPriority => RbVmomi::VIM::DasVmPriority("disabled")
                 )
                 vm_ha_spec = RbVmomi::VIM::ClusterDasVmConfigSpec(
                     :operation=>RbVmomi::VIM::ArrayUpdateOperation("edit"),
                     :info=>vm_ha_spec_info
                 )
               end

               break

             end

          }

         if vm_ha_spec.nil?
           vm_ha_spec_info = RbVmomi::VIM::ClusterDasVmConfigInfo(
               :key=>vm_mob_ref,
               :restartPriority => RbVmomi::VIM::DasVmPriority("disabled")
           )
           vm_ha_spec = RbVmomi::VIM::ClusterDasVmConfigSpec(
               :operation=>RbVmomi::VIM::ArrayUpdateOperation("add"),
               :info=>vm_ha_spec_info
           )
         end

         cluster_config_spec = RbVmomi::VIM::ClusterConfigSpec(
             :dasConfig=>cs_mob_ref.configuration.dasConfig,
             :drsConfig => cs_mob_ref.configuration.drsConfig,
             :dasVmConfigSpec=> [vm_ha_spec]
         )
         task =cs_mob_ref.ReconfigureCluster_Task(:spec => cluster_config_spec,:modify=>true )
         wait_for_task(task)
         { 'task_state' => task.info.state }
       end

      end
    end
  end
end
