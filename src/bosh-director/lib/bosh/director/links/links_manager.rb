module Bosh::Director::Links
  class LinksManager
    include Bosh::Director::IpUtil

    def initialize(logger, event_logger, serial_id)
      @logger = logger
      @event_logger = event_logger
      @serial_id = serial_id
    end

    def find_or_create_provider(
      deployment_model:,
      instance_group_name:,
      name:,
      type:
    )
      Bosh::Director::Models::Links::LinkProvider.find_or_create(
        deployment: deployment_model,
        instance_group: instance_group_name,
        name: name,
        type: type
      ).tap do |result|
        if result.serial_id != @serial_id
          result.serial_id = @serial_id
          result.save
        end
      end

    end

    def find_provider(
      deployment_model:,
      instance_group_name:,
      name:,
      type:
    )
      Bosh::Director::Models::Links::LinkProvider.find(
        deployment: deployment_model,
        instance_group: instance_group_name,
        name: name,
        type: type,
        serial_id: @serial_id,
      )
    end

    # Used by provider, not using alias because want to update existing provider intent when alias changes
    def find_or_create_provider_intent(
      link_provider:,
      link_original_name:,
      link_type:
    )
      intent = Bosh::Director::Models::Links::LinkProviderIntent.find(
        link_provider: link_provider,
        original_name: link_original_name
      )

      if intent.nil?
        intent = Bosh::Director::Models::Links::LinkProviderIntent.create(
          link_provider: link_provider,
          original_name: link_original_name,
          type: link_type,
          )
      else
        intent.type = link_type
      end

      if intent.serial_id != @serial_id
        intent.serial_id = @serial_id
      end
      intent.save
    end

    def find_or_create_consumer(
      deployment_model:,
      instance_group_name:,
      name:,
      type:
    )
      Bosh::Director::Models::Links::LinkConsumer.find_or_create(
        deployment: deployment_model,
        instance_group: instance_group_name,
        name: name,
        type: type
      ).tap do |result|
        if result.serial_id != @serial_id
          result.serial_id = @serial_id
          result.save
        end
      end
    end

    def find_consumer(
      deployment_model:,
      instance_group_name:,
      name:,
      type:
    )
      Bosh::Director::Models::Links::LinkConsumer.find(
        deployment: deployment_model,
        instance_group: instance_group_name,
        name: name,
        type: type,
        serial_id: deployment_model.links_serial_id
      )
    end

    def find_or_create_consumer_intent(
      link_consumer:,
      link_original_name:,
      link_type:
    )
      intent = Bosh::Director::Models::Links::LinkConsumerIntent.find(
        link_consumer: link_consumer,
        original_name: link_original_name
      )

      if intent.nil?
        intent = Bosh::Director::Models::Links::LinkConsumerIntent.create(
          link_consumer: link_consumer,
          original_name: link_original_name,
          type: link_type,
        )
      else
        intent.type = link_type
      end

      if intent.serial_id != @serial_id
        intent.serial_id = @serial_id
      end
      intent.save
    end

    def find_or_create_link(
      name:,
      provider_intent:,
      consumer_intent:,
      link_content:
    )
      found_link = Bosh::Director::Models::Links::Link.find(
        link_provider_intent_id: provider_intent && provider_intent[:id],
        link_consumer_intent_id: consumer_intent && consumer_intent[:id],
        link_content: link_content
      )

      unless found_link
        Bosh::Director::Models::Links::Link.create(
          name: name,
          link_provider_intent_id: provider_intent && provider_intent[:id],
          link_consumer_intent_id: consumer_intent && consumer_intent[:id],
          link_content: link_content
        )
      end
    end

    def find_link(
      name:,
      provider_intent:,
      consumer_intent:
    )
      Bosh::Director::Models::Links::Link.find(
        link_provider_intent_id: provider_intent && provider_intent[:id],
        link_consumer_intent_id: consumer_intent && consumer_intent[:id],
        name: name
      )
    end

    def resolve_deployment_links(deployment_model, options)
      dry_run = options.fetch(:dry_run, false)
      global_use_dns_entry = options.fetch(:global_use_dns_entry)

      links_consumers = deployment_model.link_consumers
      return if links_consumers.empty?

      errors = []

      links_consumers.each do |consumer|
        next if consumer.serial_id != @serial_id
        consumer.intents.each do |consumer_intent|
          next if consumer_intent.serial_id != @serial_id
          begin
            resolve_consumer_intent(consumer_intent, global_use_dns_entry, dry_run)
          rescue => e
            errors.push e.message
          end
        end
      end

      unless errors.empty?
        message = "Failed to resolve links from deployment '#{deployment_model.name}'. See errors below:\n  - "
        message += errors.join("\n  - ")
        raise message
      end
    end

    def get_links_from_deployment(deployment)
      consumers = Bosh::Director::Models::Links::LinkConsumer.where(deployment: deployment).all

      links = {}
      consumers.each do |consumer|
        links[consumer.name] = {}
        consumer.intents.each do |consumer_intent|
          consumer_intent.links.each do |link|
            next if link.link_content.nil?
            content = JSON.parse(link.link_content)
            links[consumer.name][consumer_intent.original_name] = content
          end
        end
      end

      links
    end

    def get_links_for_instance_group(deployment_model, instance_group_name)
      links = {}
      consumers = Bosh::Director::Models::Links::LinkConsumer.where(deployment: deployment_model, instance_group: instance_group_name, serial_id: deployment_model.links_serial_id)

      consumers.each do |consumer|
        links[consumer.name] = {}
        consumer.intents.each do |consumer_intent|
          next if consumer_intent.serial_id != deployment_model.links_serial_id
          consumer_intent.links.each do |link|
            content = JSON.parse(link.link_content)
            links[consumer.name][consumer_intent.original_name] = content
          end
        end
      end

      links
    end

    def bind_links_to_instance(instance)
      consumers = Bosh::Director::Models::Links::LinkConsumer.where(deployment: instance.deployment_model, instance_group: instance.instance_group_name)

      instance_model = instance.model
      consumers.each do |consumer|
        consumer.intents.each do |consumer_intent|
          next if consumer_intent.serial_id != instance.deployment_model.links_serial_id
          consumer_intent.links.each do |link|
            instance_link = Bosh::Director::Models::Links::InstancesLink.where(instance_id: instance.model.id, link_id: link.id).first
            if instance_link.nil?
              instance_model.add_link(link)
            end
            instance_link = Bosh::Director::Models::Links::InstancesLink.where(instance_id: instance.model.id, link_id: link.id).first
            if instance_link.serial_id != @serial_id
              instance_link.serial_id = @serial_id
              instance_link.save
            end
          end
        end
      end
    end

    def update_provider_intents_contents(link_providers, deployment_plan)
      link_providers.select {|provider| provider.type == 'job' && provider.serial_id == deployment_plan.model.links_serial_id}.each do |provider|
        instance_group = deployment_plan.instance_group(provider.instance_group)
        provider.intents.each do |provider_intent|
          next if provider_intent.serial_id != deployment_plan.model.links_serial_id
          metadata = {}
          metadata = JSON.parse(provider_intent.metadata) unless provider_intent.metadata.nil?

          properties = metadata['mapped_properties']

          content = Bosh::Director::DeploymentPlan::Link.new(provider.deployment.name, instance_group, properties).spec.to_json
          provider_intent.content = content
          provider_intent.save
        end
      end
    end

    def remove_unused_links(deployment_model)
      serial_id = deployment_model.links_serial_id

      #TODO LINKS: we are not filtering out disks, currently deleting all providers which are not associated with current serial_id
      Bosh::Director::Models::Links::LinkProvider.where(deployment: deployment_model).each do |provider|
        provider.intents.each do |provider_intent|
          provider_intent.delete unless provider_intent.serial_id == serial_id
        end
        unless provider.serial_id == serial_id
          provider.delete
        end

      end

      Bosh::Director::Models::Links::LinkConsumer.where(deployment: deployment_model).each do |consumer|
        consumer.intents.each do |consumer_intent|
          if consumer_intent.serial_id == serial_id
            Bosh::Director::Models::Links::Link.where(link_consumer_intent: consumer_intent).each do |link|
              instances_links = Bosh::Director::Models::Links::InstancesLink.where(link_id: link.id)
              if instances_links.count == 0
                link.delete
              end
            end
          else
            consumer_intent.delete
          end
        end
        consumer.delete unless consumer.serial_id == serial_id
      end
      #TODO LINKS: make sure there are no expired links left around, by examining the instances_link table

    end

    def resolve_consumer_intent(consumer_intent, global_use_dns_entry, dry_run)
      consumer_intent_metadata = {}
      consumer_intent_metadata = JSON.parse(consumer_intent.metadata) unless consumer_intent.metadata.nil?
      is_manual_link = !!consumer_intent_metadata['manual_link']

      if is_manual_link
        provider_intent = get_manual_link_provider_for_consumer(consumer_intent)
        link_content = provider_intent.content || '{}'

        find_or_create_link(
          name: consumer_intent.original_name,
          provider_intent: provider_intent,
          consumer_intent: consumer_intent,
          link_content: link_content
        ) unless dry_run
      else
        found_provider_intents = provider_intents_for_consumer_intent(consumer_intent, consumer_intent_metadata)
        consumer = consumer_intent.link_consumer
        current_deployment_name = consumer.deployment.name

        link_network = consumer_intent_metadata['network']
        is_explicit_link = !!consumer_intent_metadata['explicit_link']

        if found_provider_intents.empty? && consumer_intent.optional
          return unless is_explicit_link && !consumer_intent.blocked
        end

        validate_found_providers(found_provider_intents, consumer, consumer_intent, is_explicit_link, current_deployment_name, link_network)

        unless dry_run
          provider_intent = found_provider_intents.first

          #TODO Links: discuss about possibility of value of content being empty; will cause nil class error
          if is_explicit_link
            content = provider_intent.content || '{}'
            provider_intent_networks = JSON.parse(content)['networks']

            if link_network && !provider_intent_networks.include?(link_network)
              raise Bosh::Director::DeploymentInvalidLink, "Can't resolve link '#{consumer_intent.name}' in instance group '#{consumer.instance_group}' on job '#{consumer.name}' in deployment '#{current_deployment_name}' with network '#{link_network}'"
            end
          end

          link_content = extract_provider_link_content(consumer_intent_metadata, global_use_dns_entry, link_network, provider_intent)

          find_or_create_link(
            name: consumer_intent.original_name,
            provider_intent: provider_intent,
            consumer_intent: consumer_intent,
            link_content: link_content
          )
        end
      end
    end

    def migrate_links_provider_instance_group(deployment_model, instance_group_model)
      instance_group_list = instance_group_model.migrated_from.map{|h| h['name']}

      instance_group_list.each do |instance_group_name|
        deployment_model.link_providers.each do |link_provider|
          next if link_provider.instance_group != instance_group_name
          if link_provider.serial_id == deployment_model.links_serial_id
            link_provider.instance_group = instance_group_model.name
            link_provider.save
          end
        end
      end
    end

    def migrate_links_consumer_instance_group(deployment_model, instance_group_model)
      instance_group_list = instance_group_model.migrated_from.map{|h| h['name']}

      instance_group_list.each do |instance_group_name|
        deployment_model.link_consumers.each do |link_consumer|
          next if link_consumer.instance_group != instance_group_name
          if link_consumer.serial_id == deployment_model.links_serial_id
            link_consumer.instance_group = instance_group_model.name
            link_consumer.save
          end
        end
      end
    end

    private

    def extract_provider_link_content(consumer_intent_metadata, global_use_dns_entry, link_network, provider_intent)
      link_use_ip_address = consumer_intent_metadata['ip_addresses']
      provider_content = provider_intent.content || '{}'
      # determine what network name / dns entry things to use
      link_spec = update_addresses(JSON.parse(provider_content), link_network, global_use_dns_entry, link_use_ip_address)
      link_spec.to_json
    end

    def provider_intents_for_consumer_intent(consumer_intent, consumer_intent_metadata)
      consumer = consumer_intent.link_consumer
      found_provider_intents = []

      unless consumer_intent.blocked
        deployment_name = consumer_intent_metadata['from_deployment'] || consumer.deployment.name
        is_cross_deployment = (consumer.deployment.name != deployment_name)

        if is_cross_deployment
          deployment = Bosh::Director::Models::Deployment.find(name: deployment_name)
          raise Bosh::Director::DeploymentNotFound, "Can't find deployment '#{deployment_name}'" if deployment.nil?
        else
          deployment = consumer.deployment
        end

        providers = deployment.link_providers

        is_explicit_link = !!consumer_intent_metadata['explicit_link']

        providers.each do |provider|
          provider.intents.each do |provider_intent|
            next if provider_intent.type != consumer_intent.type

            if is_explicit_link
              next if provider_intent.name != consumer_intent.name
              next if is_cross_deployment && !provider_intent.shared
            end

            next if provider_intent.serial_id != deployment.links_serial_id
            found_provider_intents << provider_intent
          end
        end
      end
      found_provider_intents
    end

    def get_manual_link_provider_for_consumer(consumer_intent)
      consumer_name = consumer_intent.link_consumer.name
      consumer_instance_group = consumer_intent.link_consumer.instance_group
      consumer_intent_name = consumer_intent.original_name

      manual_provider = find_provider(
        deployment_model: consumer_intent.link_consumer.deployment,
        instance_group_name: consumer_instance_group,
        name: consumer_name,
        type: 'manual'
      )

      error_msg = "Failed to find manual link provider for consumer '#{consumer_intent_name}' in job '#{consumer_name}' in instance group '#{consumer_intent_name}'"
      raise error_msg if manual_provider.nil?

      manual_provider_intent = manual_provider.find_intent_by_name(consumer_intent_name)
      raise error_msg if manual_provider_intent.nil?

      manual_provider_intent
    end

    def update_addresses(provider_intent_content, preferred_network_name, global_use_dns_entry, link_use_ip_address)
      provider_intent_content_copy = Bosh::Common::DeepCopy.copy(provider_intent_content)
      if !provider_intent_content_copy.has_key?('default_network')
        unless link_use_ip_address.nil?
          raise Bosh::Director::LinkLookupError, 'Unable to retrieve default network from provider. Please redeploy provider deployment'
        end

        if preferred_network_name
          provider_intent_content_copy['instances'].each do |instance|
            desired_addresses = instance['addresses']
            raise Bosh::Director::LinkLookupError, "Provider link does not have network: '#{preferred_network_name}'" unless desired_addresses.key?(preferred_network_name)
            instance['address'] = desired_addresses[preferred_network_name]
            log_warning_if_applicable(instance['address'], global_use_dns_entry, instance['name'], instance['id'])
          end
        end
      else
        if link_use_ip_address.nil?
          use_dns_entries = global_use_dns_entry
        else
          use_dns_entries = !link_use_ip_address
        end

        network_name = preferred_network_name || provider_intent_content_copy['default_network']
        provider_intent_content_copy['default_network'] = network_name

        provider_intent_content_copy['instances'].each do |instance|
          if use_dns_entries
            desired_addresses = instance['dns_addresses']
          else
            desired_addresses = instance['addresses']
          end

          raise Bosh::Director::LinkLookupError, "Provider link does not have network: '#{network_name}'" unless desired_addresses.key?(network_name)

          instance['address'] = desired_addresses[network_name]
          log_warning_if_applicable(instance['address'], use_dns_entries, instance['name'], instance['id'])
        end
      end

      provider_intent_content_copy['instances']&.each do |instance|
        instance.delete('addresses')
        instance.delete('dns_addresses')
      end

      provider_intent_content_copy
    end

    def validate_found_providers(found_provider_intents, consumer, consumer_intent, is_explicit_link, current_deployment_name, link_network)
      if found_provider_intents.empty?
        if is_explicit_link
          raise Bosh::Director::DeploymentInvalidLink, "Can't resolve link '#{consumer_intent.name}' for job '#{consumer.name}' in instance group '#{consumer.instance_group}' in deployment '#{current_deployment_name}'#{" with network '#{link_network}'" unless link_network.to_s.empty?}"
        else
          raise Bosh::Director::DeploymentInvalidLink, "Can't resolve link '#{consumer_intent.original_name}' with type '#{consumer_intent.type}' for job  '#{consumer.name}' in instance_group '#{consumer_intent.link_consumer.instance_group}' in deployment '#{current_deployment_name}'#{" with network '#{link_network}'" unless link_network.to_s.empty?}"
        end
      end

      if found_provider_intents.size > 1
        if is_explicit_link
          all_link_paths = ''
          found_provider_intents.each do |provider_intent|
            all_link_paths = all_link_paths + "\n   #{provider_intent.original_name}#{" aliased as '#{provider_intent.name}'" unless provider_intent.name.nil?} (job: #{provider_intent.link_provider.name}, instance group: #{provider_intent.link_provider.instance_group})"
          end
          raise Bosh::Director::DeploymentInvalidLink, "Multiple providers of name/alias '#{consumer_intent.name}' found for job '#{consumer_intent.link_consumer.name}' in instance group '#{consumer_intent.link_consumer.instance_group}'. All of these match:#{all_link_paths}"
        else
          all_link_paths = ''
          found_provider_intents.each do |provider_intent|
            all_link_paths = all_link_paths + "\n   Deployment: #{provider_intent.link_provider.deployment.name}, instance group: #{provider_intent.link_provider.instance_group}, job: #{provider_intent.link_provider.name}, link name/alias: #{provider_intent.name}"
          end
          raise Bosh::Director::DeploymentInvalidLink, "Multiple providers of type '#{consumer_intent.type}' found for consumer link '#{consumer_intent.original_name}' in job '#{consumer_intent.link_consumer.name}' in instance group '#{consumer_intent.link_consumer.instance_group}'. All of these match:#{all_link_paths}"
        end
      end
    end

    def log_warning_if_applicable(address, dns_required, instance_name, instance_id)
      if dns_required && ip_address?(address)
        message = "DNS address not available for the link provider instance: #{instance_name}/#{instance_id}"
        @logger.warn(message)
        @event_logger.warn(message)
      elsif !dns_required && !ip_address?(address)
        message = "IP address not available for the link provider instance: #{instance_name}/#{instance_id}"
        @logger.warn(message)
        @event_logger.warn(message)
      end
    end
  end
end