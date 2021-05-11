require "base64"

module Nomade
  class Deployer
    attr_reader :nomad_job

    def initialize(nomad_endpoint, opts = {})
      @nomad_endpoint = nomad_endpoint
      @http = Nomade::Http.new(@nomad_endpoint)
      @job_builder = Nomade::JobBuilder.new(@http)
      @logger = opts.fetch(:logger, Nomade.logger)

      @timeout = opts.fetch(:timeout, 60 * 3)

      @linger = opts.fetch(:linger, 8..28)
      raise GeneralError.new("Linger needs to be a range, supplied with: #{@linger.class}") unless @linger.class == Range

      @hooks = {
        Nomade::Hooks::DEPLOY_RUNNING => [],
        Nomade::Hooks::DEPLOY_FINISHED => [],
        Nomade::Hooks::DEPLOY_FAILED => [],

        Nomade::Hooks::DISPATCH_RUNNING => [],
        Nomade::Hooks::DISPATCH_FINISHED => [],
        Nomade::Hooks::DISPATCH_FAILED => [],
      }
      add_hook(Nomade::Hooks::DEPLOY_FAILED, lambda {|_hook_type, _nomad_job, messages|
        @logger.error "Failing deploy:"
        messages.each do |message|
          @logger.error "- #{message}"
        end
      })
      add_hook(Nomade::Hooks::DISPATCH_FAILED, lambda {|_hook_type, _nomad_job, messages|
        @logger.error "Failing dispatch:"
        messages.each do |message|
          @logger.error "- #{message}"
        end
      })
    end

    def init_job(template_file, image_full_name, template_variables = {})
      @nomad_job = @job_builder.build(template_file, image_full_name, template_variables)
      @evaluation_id = nil
      @deployment_id = nil

      self
    rescue Nomade::HttpConnectionError => e
      [e.class.to_s, e.message, "Http connection error, exiting!"].compact.uniq.map{|l| @logger.error(l)}
      exit(7)
    rescue Nomade::HttpBadResponse => e
      [e.class.to_s, e.message, "Http bad response, exiting!"].compact.uniq.map{|l| @logger.error(l)}
      exit(8)
    rescue Nomade::HttpBadContentType => e
      [e.class.to_s, e.message, "Http unexpected content type!"].compact.uniq.map{|l| @logger.error(l)}
      exit(9)
    end

    def add_hook(hook, hook_method)
      if Nomade::Hooks::DEPLOY_RUNNING == hook
        @hooks[Nomade::Hooks::DEPLOY_RUNNING] << hook_method
      elsif Nomade::Hooks::DEPLOY_FINISHED == hook
        @hooks[Nomade::Hooks::DEPLOY_FINISHED] << hook_method
      elsif Nomade::Hooks::DEPLOY_FAILED == hook
        @hooks[Nomade::Hooks::DEPLOY_FAILED] << hook_method
      elsif Nomade::Hooks::DISPATCH_RUNNING == hook
        @hooks[Nomade::Hooks::DISPATCH_RUNNING] << hook_method
      elsif Nomade::Hooks::DISPATCH_FINISHED == hook
        @hooks[Nomade::Hooks::DISPATCH_FINISHED] << hook_method
      elsif Nomade::Hooks::DISPATCH_FAILED == hook
        @hooks[Nomade::Hooks::DISPATCH_FAILED] << hook_method
      else
        raise "#{hook} not supported!"
      end
    end

    def deploy!
      check_for_job_init

      run_hooks(Nomade::Hooks::DEPLOY_RUNNING, @nomad_job, nil)
      _plan
      _deploy
      run_hooks(Nomade::Hooks::DEPLOY_FINISHED, @nomad_job, nil)
    rescue Nomade::NoModificationsError => e
      run_hooks(Nomade::Hooks::DEPLOY_FAILED, @nomad_job, [e.class.to_s, e.message, "No modifications to make, exiting!"].compact.uniq)
    rescue Nomade::GeneralError => e
      run_hooks(Nomade::Hooks::DEPLOY_FAILED, @nomad_job, [e.class.to_s, e.message, "GeneralError hit, exiting!"].compact.uniq)
      exit(1)
    rescue Nomade::AllocationFailedError => e
      run_hooks(Nomade::Hooks::DEPLOY_FAILED, @nomad_job, [e.class.to_s, e.message, "Allocation failed with errors, exiting!"].compact.uniq)
      exit(3)
    rescue Nomade::UnsupportedDeploymentMode => e
      run_hooks(Nomade::Hooks::DEPLOY_FAILED, @nomad_job, [e.class.to_s, e.message, "Deployment failed with errors, exiting!"].compact.uniq)
      exit(4)
    rescue Nomade::FailedTaskGroupPlan => e
      run_hooks(Nomade::Hooks::DEPLOY_FAILED, @nomad_job, [e.class.to_s, e.message, "Couldn't plan correctly, exiting!"].compact.uniq)
      exit(5)
    rescue Nomade::DeploymentFailedError => e
      run_hooks(Nomade::Hooks::DEPLOY_FAILED, @nomad_job, [e.class.to_s, e.message, "Couldn't deploy succesfully, exiting!"].compact.uniq)
      exit(6)
    rescue Nomade::HttpConnectionError => e
      run_hooks(Nomade::Hooks::DEPLOY_FAILED, @nomad_job, [e.class.to_s, e.message, "Http connection error, exiting!"].compact.uniq)
      exit(7)
    rescue Nomade::HttpBadResponse => e
      run_hooks(Nomade::Hooks::DEPLOY_FAILED, @nomad_job, [e.class.to_s, e.message, "Http bad response, exiting!"].compact.uniq)
      exit(8)
    rescue Nomade::HttpBadContentType => e
      run_hooks(Nomade::Hooks::DEPLOY_FAILED, @nomad_job, [e.class.to_s, e.message, "Http unexpected content type!"].compact.uniq)
      exit(9)
    end

    def dispatch!(payload_data: nil, payload_metadata: {})
      check_for_job_init

      run_hooks(Nomade::Hooks::DISPATCH_RUNNING, @nomad_job, nil)
      _dispatch(payload_data, payload_metadata)
      run_hooks(Nomade::Hooks::DISPATCH_FINISHED, @nomad_job, nil)
    rescue Nomade::DispatchMetaDataFormattingError => e
      run_hooks(Nomade::Hooks::DISPATCH_FAILED, @nomad_job, [e.class.to_s, e.message, "Metadata wrongly formatted, exiting!"].compact.uniq)
      exit(10)
    rescue Nomade::DispatchMissingMetaData => e
      run_hooks(Nomade::Hooks::DISPATCH_FAILED, @nomad_job, [e.class.to_s, e.message, "Required metadata missing, exiting!"].compact.uniq)
      exit(11)
    rescue Nomade::DispatchUnknownMetaData => e
      run_hooks(Nomade::Hooks::DISPATCH_FAILED, @nomad_job, [e.class.to_s, e.message, "Unknown metadata sent to server, exiting!"].compact.uniq)
      exit(12)
    rescue Nomade::DispatchMissingPayload => e
      run_hooks(Nomade::Hooks::DISPATCH_FAILED, @nomad_job, [e.class.to_s, e.message, "Job requires payload, but payload isn't set!"].compact.uniq)
      exit(20)
    rescue Nomade::DispatchPayloadNotAllowed => e
      run_hooks(Nomade::Hooks::DISPATCH_FAILED, @nomad_job, [e.class.to_s, e.message, "Job does not allow payload!"].compact.uniq)
      exit(21)
    rescue Nomade::DispatchPayloadUnknown => e
      run_hooks(Nomade::Hooks::DISPATCH_FAILED, @nomad_job, [e.class.to_s, e.message, "API error!"].compact.uniq)
      exit(22)
    rescue Nomade::DispatchWrongJobType => e
      run_hooks(Nomade::Hooks::DISPATCH_FAILED, @nomad_job, [e.class.to_s, e.message, "Job has wrong job-type"].compact.uniq)
      exit(30)
    rescue Nomade::DispatchNotParamaterized => e
      run_hooks(Nomade::Hooks::DISPATCH_FAILED, @nomad_job, [e.class.to_s, e.message, "Job is not paramaterized"].compact.uniq)
      exit(31)
    rescue Nomade::AllocationFailedError => e
      run_hooks(Nomade::Hooks::DISPATCH_FAILED, @nomad_job, [e.class.to_s, e.message, "Allocation failed with errors, exiting!"].compact.uniq)
      exit(40)
    rescue Nomade::GeneralError => e
      run_hooks(Nomade::Hooks::DISPATCH_FAILED, @nomad_job, [e.class.to_s, e.message, "GeneralError hit, exiting!"].compact.uniq)
      exit(1)
    rescue Nomade::HttpConnectionError => e
      run_hooks(Nomade::Hooks::DISPATCH_FAILED, @nomad_job, [e.class.to_s, e.message, "Http connection error, exiting!"].compact.uniq)
      exit(7)
    rescue Nomade::HttpBadResponse => e
      run_hooks(Nomade::Hooks::DISPATCH_FAILED, @nomad_job, [e.class.to_s, e.message, "Http bad response, exiting!"].compact.uniq)
      exit(8)
    rescue Nomade::HttpBadContentType => e
      run_hooks(Nomade::Hooks::DISPATCH_FAILED, @nomad_job, [e.class.to_s, e.message, "Http unexpected content type!"].compact.uniq)
      exit(9)
    end

    def stop!(purge = false)
      check_for_job_init

      @http.stop_job(@nomad_job, purge)
    end

    private

    def check_for_job_init
      unless @nomad_job
        raise Nomade::GeneralError.new("Did you forget to run init_job?")
      end
    end

    def run_hooks(hook, job, messages)
      @hooks[hook].each do |hook_method|
        hook_method.call(hook, job, messages)
      end
    end

    def _plan
      @http.capacity_plan_job(@nomad_job)
    end

    def _deploy
      @logger.info "Deploying #{@nomad_job.job_name} (#{@nomad_job.job_type}) with #{@nomad_job.image_name_and_version}"
      @logger.info "URL: #{@nomad_endpoint}/ui/jobs/#{@nomad_job.job_name}"

      @logger.info "Checking cluster for connectivity and capacity.."
      plan_data = @http.plan_job(@nomad_job)

      sum_of_changes = plan_data["Annotations"]["DesiredTGUpdates"].map { |_group_name, task_group_updates|
        task_group_updates["Stop"] +
        task_group_updates["Place"] +
        task_group_updates["Migrate"] +
        task_group_updates["DestructiveUpdate"] +
        task_group_updates["Canary"]
      }.sum

      if sum_of_changes == 0
        raise Nomade::NoModificationsError.new
      end

      @evaluation_id = if @http.check_if_job_exists?(@nomad_job)
        @logger.info "Updating existing job"
        @http.update_job(@nomad_job)
      else
        @logger.info "Creating new job"
        @http.create_job(@nomad_job)
      end

      if @evaluation_id.empty?
        @logger.info "Parameterized job without evaluation, no more work needed"
      else
        @logger.info "EvaluationID: #{@evaluation_id}"
        @logger.info "#{@evaluation_id} Waiting until evaluation is complete"
        eval_status = nil
        while(eval_status != "complete") do
          evaluation = @http.evaluation_request(@evaluation_id)
          @deployment_id ||= evaluation["DeploymentID"]
          eval_status = evaluation["Status"]
          @logger.info "."
          sleep(1)
        end

        @logger.info "Waiting until allocations are no longer pending"
        allocations = []
        until allocations.all?{|a| a["ClientStatus"] != "pending"}
          @logger.info "."
          sleep(2)
          allocations = @http.allocations_from_evaluation_request(@evaluation_id)
        end

        case @nomad_job.job_type
        when "service"
          service_deploy
        when "batch"
          batch_deploy
        else
          raise Nomade::GeneralError.new("Job-type '#{@nomad_job.job_type}' not implemented")
        end
      end
    rescue Nomade::AllocationFailedError => e
      e.allocations.each do |allocation|
        allocation["TaskStates"].sort.each do |task_name, task_data|
          pretty_state = Nomade::Decorator.task_state_decorator(task_data["State"], task_data["Failed"])

          @logger.info ""
          @logger.info "#{allocation["ID"]} #{allocation["Name"]} #{task_name}: #{pretty_state}"
          unless task_data["Failed"]
            @logger.info "Task \"#{task_name}\" was succesfully run, skipping log-printing because it isn't relevant!"
            next
          end

          stdout = @http.get_allocation_logs(allocation["ID"], task_name, "stdout")
          if stdout != ""
            @logger.info
            @logger.info "stdout:"
            stdout.lines.each do |logline|
              @logger.info(logline.strip)
            end
          end

          stderr = @http.get_allocation_logs(allocation["ID"], task_name, "stderr")
          if stderr != ""
            @logger.info
            @logger.info "stderr:"
            stderr.lines.each do |logline|
              @logger.info(logline.strip)
            end
          end

          task_data["Events"].each do |event|
            event_type = event["Type"]
            event_time = Time.at(event["Time"]/1000/1000000).utc
            event_message = event["DisplayMessage"]

            event_details = if event["Details"].any?
              dts = event["Details"].map{|k,v| "#{k}: #{v}"}.join(", ")
              "(#{dts})"
            end

            @logger.info "[#{event_time}] #{event_type}: #{event_message} #{event_details}"
          end
        end
      end

      raise
    end

    def _dispatch(payload_data, payload_metadata)
      @logger.info "Dispatching #{@nomad_job.job_name} (#{@nomad_job.job_type}) with #{@nomad_job.image_name_and_version}"
      @logger.info "URL: #{@nomad_endpoint}/ui/jobs/#{@nomad_job.job_name}"

      @logger.info "Running sanity checks.."

      if @nomad_job.job_type != "batch"
        raise DispatchWrongJobType.new("Job-type for #{@nomad_job.job_name} is \"#{@nomad_job.job_type}\" but should be \"batch\"")
      end

      if @nomad_job.configuration(:hash)["ParameterizedJob"] == nil
        raise DispatchNotParamaterized.new("Job doesn't seem to be a paramaterized job, returned JobHash doesn't contain ParameterizedJob-key")
      end

      payload_data = if payload_data
         Base64.encode64(payload_data)
      else
        nil
      end

      payload_metadata = if payload_metadata == nil
        {}
      else
        Hash[payload_metadata.collect{|k,v| [k.to_s, v]}]
        payload_metadata.each do |key, value|
          unless [key, value].map(&:class) == [String, String]
            raise Nomade::DispatchMetaDataFormattingError.new("Dispatch metadata must only be strings: #{key}(#{key.class}) = #{value}(#{value.class})")
          end
        end
      end

      meta_required = @nomad_job.configuration(:hash)["ParameterizedJob"]["MetaRequired"]
      meta_optional = @nomad_job.configuration(:hash)["ParameterizedJob"]["MetaOptional"]
      payload       = @nomad_job.configuration(:hash)["ParameterizedJob"]["Payload"]

      if meta_required
        @logger.info "Dispatch job expects the following metakeys: #{meta_required.join(", ")}"
        meta_required.each do |required_key|
          unless payload_metadata.keys.include?(required_key)
            raise Nomade::DispatchMissingMetaData.new("Dispatch job expects metakey #{required_key} but it was not set")
          end
        end
      end

      allowed_meta_tags = [meta_required, meta_optional].flatten.uniq
      @logger.info "Dispatch job allows the following metakeys: #{allowed_meta_tags.join(", ")}"
      if payload_metadata
        payload_metadata.keys.each do |metadata_key|
          unless allowed_meta_tags.include?(metadata_key)
            raise Nomade::DispatchUnknownMetaData.new("Dispatch job does not allow #{metadata_key} to be set!")
          end
        end
      end

      case payload
      when "optional", ""
        @logger.info "Expectation for Payload is: optional"
      when "required"
        @logger.info "Expectation for Payload is: required"

        unless payload_data
          raise Nomade::DispatchMissingPayload.new("Dispatch job expects payload_data, but we don't supply any!")
        end
      when "forbidden"
        @logger.info "Expectation for Payload is: forbidden"

        if payload_data
          raise Nomade::DispatchPayloadNotAllowed.new("Dispatch job do not allow payload_data!")
        end
      else
        raise Nomade::DispatchPayloadUnknown.new("Invalid value for [\"ParameterizedJob\"][\"Payload\"] = #{payload}")
      end

      @logger.info "Checking cluster for connectivity and capacity.."
      _plan_data = @http.plan_job(@nomad_job)

      dispatch_job = @http.dispatch_job(@nomad_job, payload_data: payload_data, payload_metadata: payload_metadata)
      @evaluation_id = dispatch_job["EvalID"]

      @logger.info "Waiting until allocations are no longer pending"
      allocations = []
      until !allocations.empty? && allocations.all?{|a| a["ClientStatus"] != "pending"}
        @logger.info "."
        sleep(2)
        allocations = @http.allocations_from_evaluation_request(@evaluation_id)
      end

      batch_deploy
    end

    def service_deploy
      @logger.info "Waiting until tasks are placed"
      deploy_timeout = Time.now.utc + @timeout
      @logger.info ".. deploy timeout is #{deploy_timeout}"

      json = @http.deployment_request(@deployment_id)
      @logger.info "#{json["JobID"]} version #{json["JobVersion"]}"

      need_manual_promotion = json["TaskGroups"].values.any?{|tg| tg["DesiredCanaries"] > 0 && tg["AutoPromote"] == false}
      need_manual_rollback  = json["TaskGroups"].values.any?{|tg| tg["DesiredCanaries"] > 0 && tg["AutoRevert"] == false}

      manual_work_required = case [need_manual_promotion, need_manual_rollback]
      when [true, true]
        @logger.info "Job needs manual promotion/rollback, we'll take care of that!"
        true
      when [false, false]
        @logger.info "Job manages its own promotion/rollback, we will just monitor in a hands-off mode!"
        false
      when [false, true]
        raise UnsupportedDeploymentMode.new("Unsupported deployment-mode, manual-promotion=#{need_manual_promotion}, manual-rollback=#{need_manual_rollback}")
      when [true, false]
        raise UnsupportedDeploymentMode.new("Unsupported deployment-mode, manual-promotion=#{need_manual_promotion}, manual-rollback=#{need_manual_rollback}")
      end

      announced_completed = []
      promoted = false
      succesful_deployment = nil
      while(succesful_deployment == nil) do
        json = @http.deployment_request(@deployment_id)

        json["TaskGroups"].each do |task_name, task_data|
          next if announced_completed.include?(task_name)

          desired_canaries = task_data["DesiredCanaries"]
          desired_total = task_data["DesiredTotal"]
          _placed_allocations = task_data["PlacedAllocs"]
          healthy_allocations = task_data["HealthyAllocs"]
          _unhealthy_allocations = task_data["UnhealthyAllocs"]

          if manual_work_required
            @logger.info "#{json["ID"]} #{task_name}: #{healthy_allocations}/#{desired_canaries}/#{desired_total} (Healthy/WantedCanaries/Total)"
            announced_completed << task_name if healthy_allocations == desired_canaries && desired_canaries > 0
          else
            @logger.info "#{json["ID"]} #{task_name}: #{healthy_allocations}/#{desired_total} (Healthy/Total)"
            announced_completed << task_name if healthy_allocations == desired_total
          end
        end

        if manual_work_required
          if json["Status"] == "failed"
            @logger.info "#{json["Status"]}: #{json["StatusDescription"]}"
            succesful_deployment = false
          end

          if succesful_deployment == nil && Time.now.utc > deploy_timeout
            @logger.info "Timeout hit, rolling back deploy!"
            @http.fail_deployment(@deployment_id)
            succesful_deployment = false
          end

          if succesful_deployment == nil && json["TaskGroups"].values.all?{|tg| tg["HealthyAllocs"] >= tg["DesiredCanaries"]}
            if !promoted
              random_linger = rand(@linger)
              @logger.info "Lingering around for #{random_linger} seconds before deployment.."
              sleep(random_linger)

              @logger.info "Promoting #{@deployment_id} (version #{json["JobVersion"]})"
              @http.promote_deployment(@deployment_id)
              promoted = true
              @logger.info ".. promoted!"
            else
              if json["Status"] == "successful"
                succesful_deployment = true
              else
                @logger.info "Waiting for promotion to complete #{@deployment_id} (version #{json["JobVersion"]})"
              end
            end
          end
        else
          case json["Status"]
          when "running"
            # no-op
          when "failed"
            @logger.info "#{json["Status"]}: #{json["StatusDescription"]}"
            succesful_deployment = false
          when "successful"
            @logger.info "#{json["Status"]}: #{json["StatusDescription"]}"
            succesful_deployment = true
          end
        end

        sleep 5 if succesful_deployment == nil
      end

      if succesful_deployment
        @logger.info ""
        @logger.info "#{@deployment_id} (version #{json["JobVersion"]}) was succesfully deployed!"

        true
      else
        @logger.warn ""
        @logger.warn "#{@deployment_id} (version #{json["JobVersion"]}) deployment _failed_!"

        raise DeploymentFailedError.new
      end
    end

    def batch_deploy
      alloc_status = nil
      announced_dead = []

      while(alloc_status != true) do
        allocations = @http.allocations_from_evaluation_request(@evaluation_id)

        allocations.each do |allocation|
          allocation["TaskStates"].sort.each do |task_name, task_data|
            full_task_address = [allocation["ID"], allocation["Name"], task_name].join(" ")
            pretty_state = Nomade::Decorator.task_state_decorator(task_data["State"], task_data["Failed"])

            unless announced_dead.include?(full_task_address)
              @logger.info "#{allocation["ID"]} #{allocation["Name"]} #{task_name}: #{pretty_state}"

              if task_data["State"] == "dead"
                announced_dead << full_task_address
              end
            end
          end
        end

        tasks           = get_tasks(allocations)
        upcoming_tasks  = get_upcoming_tasks(tasks)
        _succesful_tasks = get_succesful_tasks(tasks)
        failed_tasks    = get_failed_tasks(tasks)

        if upcoming_tasks.size == 0
          if failed_tasks.any?
            raise Nomade::AllocationFailedError.new(@evaluation_id, allocations)
          end

          @logger.info "Deployment complete"

          allocations.each do |allocation|
            allocation["TaskStates"].sort.each do |task_name, task_data|
              pretty_state = Nomade::Decorator.task_state_decorator(task_data["State"], task_data["Failed"])

              @logger.info ""
              @logger.info "#{allocation["ID"]} #{allocation["Name"]} #{task_name}: #{pretty_state}"

              stdout = @http.get_allocation_logs(allocation["ID"], task_name, "stdout")
              if stdout != ""
                @logger.info
                @logger.info "stdout:"
                stdout.lines.each do |logline|
                  @logger.info(logline.strip)
                end
              end

              stderr = @http.get_allocation_logs(allocation["ID"], task_name, "stderr")
              if stderr != ""
                @logger.info
                @logger.info "stderr:"
                stderr.lines.each do |logline|
                  @logger.info(logline.strip)
                end
              end
            end
          end

          alloc_status = true
        end

        sleep(1)
      end

      true
    end

    # Task-helpers
    def get_tasks(allocations)
      [].tap do |it|
        allocations.each do |allocation|
          allocation["TaskStates"].sort.each do |task_name, task_data|
            it << {
              "Name" => task_name,
              "Allocation" => allocation,
            }.merge(task_data)
          end
        end
      end
    end

    def get_upcoming_tasks(tasks)
      [].tap do |it|
        tasks.each do |task|
          if ["pending", "running"].include?(task["State"])
            it << task
          end
        end
      end
    end

    def get_succesful_tasks(tasks)
      [].tap do |it|
        tasks.each do |task|
          if task["State"] == "dead" && task["Failed"] == false
            it << task
          end
        end
      end
    end

    def get_failed_tasks(tasks)
      [].tap do |it|
        tasks.each do |task|
          if task["State"] == "dead" && task["Failed"] == true
            it << task
          end
        end
      end
    end

  end
end
