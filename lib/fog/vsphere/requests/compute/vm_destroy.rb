module Fog
  module Compute
    class Vsphere
      class Real

        def vm_destroy(options = {})
          raise ArgumentError, "instance_uuid is a required parameter" unless options.has_key? 'instance_uuid'

          # Find the VM Object
          search_filter = { :uuid => options['instance_uuid'], 'vmSearch' => true, 'instanceUuid' => true }
          vm_mob_ref = @connection.searchIndex.FindAllByUuid(search_filter).first

          unless vm_mob_ref.kind_of? RbVmomi::VIM::VirtualMachine
            raise Fog::Vsphere::Errors::NotFound,
                  "Could not find VirtualMachine with instance uuid #{options['instance_uuid']}"
          end

          power_state = convert_vm_mob_ref_to_attr_hash(vm_mob_ref).fetch('power_state')
          if  power_state!= "poweredOff"
            vm_power_off( 'instance_uuid' => options['instance_uuid'], 'force'=> true )
          end

          task = vm_mob_ref.Destroy_Task
          wait_for_task(task)
          { 'task_state' => task.info.state }
        end

      end

      class Mock

        def vm_destroy(options = {})
          raise ArgumentError, "instance_uuid is a required parameter" unless options.has_key? 'instance_uuid'
          { 'task_state' => 'success' }
        end

      end
    end
  end
end
