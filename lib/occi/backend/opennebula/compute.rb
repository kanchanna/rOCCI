##############################################################################
#  Copyright 2011 Service Computing group, TU Dortmund
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
##############################################################################

##############################################################################
# Description: OpenNebula Backend
# Author(s): Hayati Bice, Florian Feldhaus, Piotr Kasprzak
##############################################################################

require 'occi/backend/opennebula/ComputeERB'

require 'occi/Log'

module OCCI
  module Backend
    module OpenNebula

      # ---------------------------------------------------------------------------------------------------------------------
      module Compute

        TEMPLATECOMPUTERAWFILE = 'occi_one_template_compute.erb'

        # ---------------------------------------------------------------------------------------------------------------------       
        #        private
        # ---------------------------------------------------------------------------------------------------------------------

        # ---------------------------------------------------------------------------------------------------------------------     
        # PARSE OPENNEBULA COMPUTE OBJECT
        def compute_parse_backend_object(backend_object)

          backend_object.info

          if backend_object['TEMPLATE/OCCI_ID'].nil?
            raise "no backend ID found" if backend_object.id.nil?
            occi_id = self.generate_occi_id(OCCI::Infrastructure::Compute::KIND, backend_object.id.to_s)
          else
            occi_id = backend_object['TEMPLATE/OCCI_ID']
          end

          kind = "http://schemas.ogf.org/occi/infrastructure#compute"

          mixins = []
          # mixins << OCCI::Backend::ONE::VirtualMachine::MIXIN
          mixins << OCCI::Registry.get_by_id('http://opennebula.org/occi/infrastructure#virtualmachine')

          attributes = Hashie::Mash.new
          # parse all parameters from OpenNebula to OCCI
          attributes.occi.core.id = occi_id
          attributes.occi.core.title = backend_object['NAME']
          attributes.occi.core.summary = backend_object['TEMPLATE/DESCRIPTION'] if backend_object['TEMPLATE/DESCRIPTION']

          attributes.occi.compute.cores = backend_object['TEMPLATE/VCPU']
          attributes.occi.compute.architecture = "x64" if backend_object['TEMPLATE/ARCHITECTURE'] == "x86_64"
          attributes.occi.compute.architecture = "x86" if backend_object['TEMPLATE/ARCHITECTURE'] == "i686"
          attributes.occi.compute.memory = backend_object['TEMPLATE/MEMORY'].to_f/1000

          attributes.opennebula.virtualmachine.cpu = backend_object['TEMPLATE/CPU'] if backend_object['TEMPLATE/CPU']
          attributes.opennebula.virtualmachine.kernel = backend_object['TEMPLATE/KERNEL'] if backend_object['TEMPLATE/KERNEL']
          attributes.opennebula.virtualmachine.initrd = backend_object['TEMPLATE/INITRD'] if backend_object['TEMPLATE/INITRD']
          attributes.opennebula.virtualmachine.root = backend_object['TEMPLATE/ROOT'] if backend_object['TEMPLATE/ROOT']
          attributes.opennebula.virtualmachine.kernel_cmd = backend_object['TEMPLATE/KERNEL_CMD'] if backend_object['TEMPLATE/KERNEL_CMD']
          attributes.opennebula.virtualmachine.bootloader = backend_object['TEMPLATE/BOOTLOADER'] if backend_object['TEMPLATE/BOOTLOADER']
          attributes.opennebula.virtualmachine.boot = backend_object['TEMPLATE/BOOT'] if backend_object['TEMPLATE/BOOT']

          compute = OCCI::Core::Resource.new(:kind => kind, :mixins => mixins, :attributes => attributes)

          # VNC handling
          if backend_object['TEMPLATE/GRAPHICS/TYPE'] == 'vnc' \
          and backend_object['HISTORY_RECORDS/HISTORY/HOSTNAME'] \
          and not OCCI::Server.config[:novnc_path].nil? \
          and not OCCI::Server.config[:vnc_proxy_base_port].nil?

            vnc_host = backend_object['HISTORY_RECORDS/HISTORY/HOSTNAME']
            vnc_port = backend_object['TEMPLATE/GRAPHICS/PORT']

            vnc_proxy_host = URI.parse(OCCI::Server.location).host

            # The noVNC proxy_port
            proxy_port = OCCI::Server.config[:vnc_proxy_base_port].to_i + vnc_port.to_i

            OCCI::Log.debug("NOVNC path: #{OCCI::Server.config[:novnc_path]}")
            OCCI::Log.debug("Graphics type: #{backend_object['TEMPLATE/GRAPHICS/TYPE']}")
            OCCI::Log.debug("VNC base port: #{OCCI::Server.config[:vnc_proxy_base_port]}")
            OCCI::Log.debug("VNC port: #{vnc_port}")
            OCCI::Log.debug("VNC host: #{vnc_host}")

            compute.mixins << OCCI::Registry.get_by_id("http://schemas.ogf.org/occi/infrastructure/compute#console")

            if occi_object.attributes['opennebula.vm.vnc'].nil? or occi_object.backend[:novnc_pipe].nil?

              # CREATE PROXY FOR VNC SERVER
              begin
                novnc_cmd = "#{OCCI::Server.config[:novnc_path]}/utils/websockify"
                pipe = IO.popen("#{novnc_cmd} --web #{OCCI::Server.config[:novnc_path]} #{proxy_port} #{vnc_host}:#{vnc_port}")

                if pipe
                  vnc_url = OCCI::Server.config[:server].chomp('/') + ':' + vnc_port + '/vnc_auto.html?host=' + vnc_proxy_host + '&port=' + vnc_port
                  OCCI::Log.debug("VNC URL: #{vnc_url}")
                  occi_object.backend[:novnc_pipe] = pipe
                  occi_object.attributes['opennebula.vm.vnc'] = vnc_host + ':' + vnc_port
                  occi_object.attributes['opennebula.vm.web_vnc'] = vnc_url
                end
              rescue Exception => e
                OCCI::Log.error("Error in creating VNC proxy: #{e.message}")
              end
            end
            OCCI::Registry.get_by_id(kind).entities << compute
          end

          occi_object.backend[:id] = backend_object.id
          occi_object = self.compute_parse_links(occi_object, backend_object)
          OCCI::Log.info("OCCI compute object created/updated")
          return occi_object
        end

        # ---------------------------------------------------------------------------------------------------------------------
        # PARSE OPENNEBULA DEPENDENCIES TO E.G. STORAGE AND NETWORK LINKS
        def compute_parse_links(occi_object, backend_object)
          # create links for all storage instances

          backend_object.each('TEMPLATE/DISK') do |disk|
            attributes = {}
            target = nil
            OCCI::Log.debug("Storage Backend ID: #{disk['IMAGE_ID']}")
            OCCI::Infrastructure::Storage::KIND.entities.each do |storage|
              target = storage if storage.backend[:id].to_i == disk['IMAGE_ID'].to_i
            end
            if target == nil
              backend_object = Image.new(Image.build_xml(disk['IMAGE_ID']), @one_client)
              backend_object.info
              target = self.storage_parse_backend_object(backend_object)
            end
            source = occi_object
            attributes["occi.core.target"] = target.get_location
            attributes["occi.core.source"] = source.get_location
            # check if link already exists
            occi_id = self.generate_occi_id(OCCI::Infrastructure::StorageLink::KIND, disk['IMAGE_ID'].to_s)
            storagelink_location = OCCI::Rendering::HTTP::LocationRegistry.get_location_of_object(OCCI::Infrastructure::StorageLink::KIND)
            link = OCCI::Rendering::HTTP::LocationRegistry.get_object(storagelink_location + occi_id)
            if link.nil?
              # create new link
              attributes['occi.core.id'] = occi_id
              link = OCCI::Infrastructure::StorageLink.new(attributes)
              OCCI::Rendering::HTTP::LocationRegistry.register(link.get_location, link)
            end
            source.links.push(link).uniq!
            target.links.push(link).uniq!
            OCCI::Log.debug("Link successfully created")
          end

          #create links for all network instances
          backend_object.each('TEMPLATE/NIC') do |nic|
            attributes = {}
            OCCI::Log.debug("Network Backend ID: #{nic['NETWORK_ID']}")
            target = nil
            OCCI::Infrastructure::Network::KIND.entities.each do |network|
              target = network if network.backend[:id].to_i == nic['NETWORK_ID'].to_i
              OCCI::Log.debug(target.kind.term) if target != nil
            end
            if target.nil?
              backend_object = VirtualNetwork.new(VirtualNetwork.build_xml(nic['NETWORK_ID']), @one_client)
#              pool = VirtualNetworkPool(@one_client)
#              pool.info(INFO_ACL, nic['NETWORK_ID'], nic['NETWORK_ID'])

              backend_object.info
              target = self.network_parse_backend_object(backend_object)
            end
            source = occi_object
            attributes["occi.core.target"] = target.get_location
            attributes["occi.core.source"] = source.get_location
            # check if link already exists
            occi_id = self.generate_occi_id(OCCI::Infrastructure::Networkinterface::KIND, nic['NETWORK_ID'].to_s)
            networkinterface_location = OCCI::Rendering::HTTP::LocationRegistry.get_location_of_object(OCCI::Infrastructure::Networkinterface::KIND)
            link = OCCI::Rendering::HTTP::LocationRegistry.get_object(networkinterface_location + occi_id)
            if link.nil?
              # create new link
              attributes['occi.core.id'] = occi_id
              link = OCCI::Infrastructure::Networkinterface.new(attributes)
              OCCI::Rendering::HTTP::LocationRegistry.register(link.get_location, link)
            end
            link.attributes['occi.networkinterface.address'] = nic['IP'] unless nic['IP'].nil?
            link.attributes['occi.networkinterface.mac'] = nic['MAC'] unless nic['MAC'].nil?
            source.links.push(link).uniq!
            target.links.push(link).uniq!
            OCCI::Log.debug("Link successfully created")
          end

          return occi_object
        end

        # ---------------------------------------------------------------------------------------------------------------------
        # ALI: Monitoring
        #        def monitor(parameter)
        #          backend_object = VirtualMachine.new(VirtualMachine.build_xml(@backend[:id]), $backend.one_client)
        #          backend_object.info
        #          occi_object = parse_backend_object(backend_object)
        #          monitoring_resources = [ :cpu] if parameter == "cpu"
        #          monitoring_resources = [ :memory] if parameter == "memory"
        #          monitoring_resources = [ :net_rx] if parameter == "net_rx"
        #          monitoring_resources = [:net_tx] if parameter == "net_tx"
        #          occi_object.attributes["compute.cpu.value"]= watch_client.resource_monitoring(occi_object.backend[:id],monitoring_resources)
        #        end

        # ---------------------------------------------------------------------------------------------------------------------
        public
        # ---------------------------------------------------------------------------------------------------------------------

        # ---------------------------------------------------------------------------------------------------------------------
        def compute_deploy(compute)
          # initialize backend object as VM or VM template
          # TODO: figure out templates
          # backend_object=Template.new(Template.build_xml, $backend.one_client)
          template_mixin = compute.mixins.select { |m| m.related == OCCI::Infrastructure::ResourceTemplate::MIXIN }

          if template_mixin.empty?

            backend_object = VirtualMachine.new(VirtualMachine.build_xml, @one_client)

            compute_erb = ComputeERB.new

            compute_erb.compute = compute
            compute_erb.storage = []
            compute_erb.networks = []
            compute_erb.external_storage = []
            compute_erb.nfs_mounts = []

            if compute.links != nil
              compute.links.each do |link|
                OCCI::Log.debug("Processing link: #{link.kind.type_identifier}, attributes: #{link.attributes.inspect}")
                target_URI = link.attributes['occi.core.target'] if URI.parse(link.attributes['occi.core.target']).absolute?
                target = OCCI::Rendering::HTTP::LocationRegistry.get_object(link.attributes['occi.core.target'])

                case link.kind.term
                  when 'storagelink'
                    # TODO: incorporate mountpoint here (e.g. occi.storagelink.mountpoint )
                    # Check for nfs mount points
                    if $nfs_support
                      if target.kind == OCCI::Infrastructure::NFSStorage::KIND
                        # Keep track of nfs-export -> mount-point tuples
                        OCCI::Log.debug("Adding nfs mount: #{target.attributes["occi.storage.export"]} -> #{link.attributes['occi.storagelink.mountpoint']}")
                        compute_erb.nfs_mounts << [target.attributes['occi.storage.export'], link.attributes['occi.storagelink.mountpoint']]
                        next
                      end
                    end

                    if not target.nil?
                      compute_erb.storage << [target, link]
                    elsif not target_URI.nil?
                      compute_erb.external_storage << target_URI
                    end

                  when 'networkinterface'
                    if not target.nil?
                      compute_erb.networks << [target, link]
                    end

                  when 'link'
                    case target.kind.term
                      when 'storage'
                        compute_erb.storage << [target, link]
                      when 'network'
                        compute_erb.networks << [target, link]
                    end unless target.nil?
                end
              end
            end

            template_raw = OCCI::Server.config["TEMPLATE_LOCATION"] + TEMPLATECOMPUTERAWFILE
            compute_template = ERB.new(File.read(template_raw)).result(compute_erb.get_binding)

            OCCI::Log.debug("Parsed template #{compute_template}")
            rc = backend_object.allocate(compute_template)
            check_rc(rc)
            OCCI::Log.debug("Return code from OpenNebula #{rc}") if rc != nil
            compute.backend[:id] = backend_object.id
          else
            backend_template = Template.new(Template.build_xml(template_mixin.backend[:id]), @one_client)
            res = backend_template.instantiate
            check_rc(res)
            compute.backend[:id] = backend_id
            compute_refresh(compute)
          end

          OCCI::Log.debug("OpenNebula ID of virtual machine: #{compute.backend[:id]}")
          OCCI::Log.debug("OpenNebula automatically triggers action start for Virtual Machines")
          OCCI::Log.debug("Changing state to started")
        end

        # ---------------------------------------------------------------------------------------------------------------------
        def compute_refresh(compute)
          OCCI::Log.debug("Refreshing compute object with backend ID: #{compute.backend[:id]}")
          backend_object = VirtualMachine.new(VirtualMachine.build_xml(compute.backend[:id]), @one_client)

          backend_object.info

          occi_object = compute_parse_backend_object(backend_object)
          if occi_object.nil?
            OCCI::Log.debug("Problems refreshing backend object")
          else
            # TODO: parse links?

            # merge new attributes with existing attributes, by overwriting existing attributes with refreshed values
            compute.attributes.merge!(occi_object.attributes)
            # concat mixins and remove duplicate mixins
            compute.mixins.concat(occi_object.mixins).uniq!
            # update state
            compute_update_state(compute)
          end
        end

        # ---------------------------------------------------------------------------------------------------------------------
        def compute_update_state(compute)
          backend_object = VirtualMachine.new(VirtualMachine.build_xml(compute.backend[:id]), @one_client)
          backend_object.info
          OCCI::Log.debug("current VM state is: #{backend_object.lcm_state_str}")
          state = case backend_object.lcm_state_str
                    when "RUNNING" then
                      OCCI::Infrastructure::Compute::STATE_ACTIVE
                    when "PROLOG", "BOOT", "SAVE_STOP", "SAVE_SUSPEND", "SAVE_MIGRATE", "MIGRATE", "PROLOG_MIGRATE", "PROLOG_RESUME" then
                      OCCI::Infrastructure::Compute::STATE_INACTIVE
                    when "SUSPENDED" then
                      OCCI::Infrastructure::Compute::STATE_SUSPENDED
                    else
                      OCCI::Infrastructure::Compute::STATE_INACTIVE
                  end
          compute.state_machine.set_state(state)
          compute.attributes['occi.compute.state'] = compute.state_machine.current_state.name
        end

        # ---------------------------------------------------------------------------------------------------------------------
        def compute_delete(compute)
          backend_object=VirtualMachine.new(VirtualMachine.build_xml(compute.backend[:id]), @one_client)

          rc = backend_object.finalize
          check_rc(rc)
          OCCI::Log.debug("killing NoVNC pipe with pid #{compute.backend[:novnc_pipe].pid}") unless compute.backend[:novnc_pipe].nil?
          Process.kill 'INT', compute.backend[:novnc_pipe].pid unless compute.backend[:novnc_pipe].nil?
        end

        # ---------------------------------------------------------------------------------------------------------------------
        # GET ALL COMPUTE INSTANCES
        def compute_register_all_instances
          backend_object_pool = VirtualMachinePool.new(@one_client)
          backend_object_pool.info(OCCI::Backend::OpenNebula::OpenNebula::INFO_ACL, -1, -1, OpenNebula::VirtualMachinePool::INFO_NOT_DONE)
          compute_register_all_objects(backend_object_pool)
        end

        # ---------------------------------------------------------------------------------------------------------------------
        # GET ALL COMPUTE TEMPLATES
        def compute_register_all_templates
          backend_object_pool = TemplatePool.new(@one_client, INFO_ACL)
          backend_object_pool.info
          compute_register_all_objects(backend_object_pool, template = true)
        end

        # ---------------------------------------------------------------------------------------------------------------------
        # GET ALL COMPUTE OBJECTS
        def compute_register_all_objects(backend_object_pool, template = false)
          occi_objects = []
          backend_object_pool.each do |backend_object|
            OCCI::Log.debug("ONE compute object: #{backend_object}")
            occi_object = compute_parse_backend_object(backend_object)
            if occi_object.nil?
              OCCI::Log.debug("Error creating occi resource from backend")
            else
              OCCI::Log.debug("Compute Backend ID: #{occi_object.backend[:id]}")
              OCCI::Log.debug("OCCI compute object location: #{occi_object.get_location}")
              occi_objects << occi_object
            end
          end
        end

        # ---------------------------------------------------------------------------------------------------------------------
        # COMPUTE ACTIONS
        # ---------------------------------------------------------------------------------------------------------------------

        # ---------------------------------------------------------------------------------------------------------------------
        def compute_action_dummy(compute, parameters)
        end

        # ---------------------------------------------------------------------------------------------------------------------
        # COMPUTE Action start
        def compute_start(compute, parameters)
          backend_object = VirtualMachine.new(VirtualMachine.build_xml(compute.backend[:id]), @one_client)
          rc = backend_object.resume
          check_rc(rc)
        end

        # ---------------------------------------------------------------------------------------------------------------------
        # Action stop
        def compute_stop(compute, parameters)
          backend_object = VirtualMachine.new(VirtualMachine.build_xml(compute.backend[:id]), @one_client)
          # TODO: implement parameters when available in OpenNebula
          case parameters
            when 'method="graceful"'
              OCCI::Log.debug("Trying to stop VM graceful")
              rc = backend_object.shutdown
            when 'method="acpioff"'
              OCCI::Log.debug("Trying to stop VM via ACPI off")
              rc = backend_object.shutdown
            else # method="poweroff" or no method specified
              OCCI::Log.debug("Powering off VM")
              rc = backend_object.shutdown
          end
          check_rc(rc)
        end

        # ---------------------------------------------------------------------------------------------------------------------
        # Action restart
        def compute_restart(compute, parameters)
          backend_object = VirtualMachine.new(VirtualMachine.build_xml(compute.backend[:id]), @one_client)
          # TODO: implement parameters when available in OpenNebula
          case parameters
            when "graceful"
              rc = vm.resubmit
            when "warm"
              rc = vm.resubmit
            else # "cold" or no parameter specified
              rc = vm.resubmit
          end
          check_rc(rc)
        end

        # ---------------------------------------------------------------------------------------------------------------------
        # Action suspend
        def compute_suspend(compute, parameters)
          backend_object = VirtualMachine.new(VirtualMachine.build_xml(compute.backend[:id]), @one_client)
          rc = vm.suspend
          check_rc(rc)
        end

      end

    end
  end
end
